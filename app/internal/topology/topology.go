package topology

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	ecstypes "github.com/aws/aws-sdk-go-v2/service/ecs/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
)

type Application struct {
	AvailabilityZone string `json:"availability_zone"`
	Cluster          string `json:"cluster"`
	LaunchType       string `json:"launch_type"`
	Region           string `json:"region"`
	Revision         string `json:"revision"`
	TaskDefinition   string `json:"task_definition"`
	TaskID           string `json:"task_id"`
}

type Database struct {
	AvailabilityZone          string `json:"availability_zone"`
	Identifier                string `json:"identifier"`
	ReadReplicaSource         string `json:"read_replica_source,omitempty"`
	Region                    string `json:"region"`
	Role                      string `json:"role"`
	SecondaryAvailabilityZone string `json:"secondary_availability_zone,omitempty"`
	Status                    string `json:"status"`
	Available                 bool   `json:"available"`
	MultiAZ                   bool   `json:"multi_az"`
}

type Compute struct {
	Name              string   `json:"name"`
	Region            string   `json:"region"`
	AvailabilityZones []string `json:"availability_zones"`
	TaskIDs           []string `json:"task_ids"`
	DesiredCount      int32    `json:"desired_count"`
	RunningCount      int32    `json:"running_count"`
	MultiAZ           bool     `json:"multi_az"`
	Available         bool     `json:"available"`
}

type Snapshot struct {
	Application Application `json:"application"`
	Database    Database    `json:"database"`
	Compute     Compute     `json:"compute"`
}

type ecsAPI interface {
	DescribeServices(context.Context, *ecs.DescribeServicesInput, ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error)
	DescribeTasks(context.Context, *ecs.DescribeTasksInput, ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error)
	ListTasks(context.Context, *ecs.ListTasksInput, ...func(*ecs.Options)) (*ecs.ListTasksOutput, error)
}

type rdsAPI interface {
	DescribeDBInstances(context.Context, *rds.DescribeDBInstancesInput, ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error)
}

type Service struct {
	computeCacheTill  time.Time
	databaseCacheTill time.Time
	ecsClient         ecsAPI
	rdsClient         rdsAPI
	httpClient        *http.Client
	databaseID        string
	metadataURL       string
	region            string
	cachedDB          Database
	cachedCompute     Compute
	mu                sync.Mutex
}

// New creates a topology reader that degrades cleanly outside ECS and AWS.
func New(ctx context.Context, region, databaseID string) *Service {
	s := &Service{
		databaseID:  databaseID,
		httpClient:  &http.Client{Timeout: time.Second},
		metadataURL: os.Getenv("ECS_CONTAINER_METADATA_URI_V4"),
		region:      region,
	}
	if region == "" || region == "local" {
		return s
	}
	if cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region)); err == nil {
		s.ecsClient = ecs.NewFromConfig(cfg)
		if databaseID != "" {
			s.rdsClient = rds.NewFromConfig(cfg)
		}
	}
	return s
}

// Snapshot returns the responding ECS task and cached RDS control-plane state.
func (s *Service) Snapshot(ctx context.Context) Snapshot {
	application := s.application(ctx)
	return Snapshot{
		Application: application,
		Compute:     s.compute(ctx, application.Cluster, application.TaskDefinition),
		Database:    s.database(ctx),
	}
}

func (s *Service) application(ctx context.Context) Application {
	app := Application{Region: s.region}
	if s.metadataURL == "" {
		return app
	}

	var metadata struct {
		AvailabilityZone string `json:"AvailabilityZone"`
		Cluster          string `json:"Cluster"`
		Family           string `json:"Family"`
		LaunchType       string `json:"LaunchType"`
		Revision         string `json:"Revision"`
		TaskARN          string `json:"TaskARN"`
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.metadataURL+"/task", nil)
	if err != nil {
		return app
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return app
	}
	defer func() {
		if err := resp.Body.Close(); err != nil {
			slog.Error("close ECS metadata response failed", "error", err)
		}
	}()
	if resp.StatusCode != http.StatusOK || json.NewDecoder(resp.Body).Decode(&metadata) != nil {
		return app
	}

	app.AvailabilityZone = metadata.AvailabilityZone
	app.Cluster = metadata.Cluster
	app.LaunchType = metadata.LaunchType
	app.Revision = metadata.Revision
	app.TaskDefinition = metadata.Family
	app.TaskID = shortID(metadata.TaskARN)
	return app
}

func (s *Service) compute(ctx context.Context, cluster, serviceName string) Compute {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Now().Before(s.computeCacheTill) {
		return s.cachedCompute
	}

	compute := Compute{Name: serviceName, Region: s.region, AvailabilityZones: []string{}, TaskIDs: []string{}}
	cache := func() Compute {
		s.cachedCompute = compute
		s.computeCacheTill = time.Now().Add(15 * time.Second)
		return compute
	}
	if s.ecsClient == nil || cluster == "" || serviceName == "" {
		return cache()
	}

	services, err := s.ecsClient.DescribeServices(ctx, &ecs.DescribeServicesInput{
		Cluster:  aws.String(cluster),
		Services: []string{serviceName},
	})
	if err != nil || len(services.Services) == 0 {
		return cache()
	}
	compute.Available = true
	compute.DesiredCount = services.Services[0].DesiredCount
	compute.RunningCount = services.Services[0].RunningCount

	tasks, err := s.ecsClient.ListTasks(ctx, &ecs.ListTasksInput{
		Cluster:       aws.String(cluster),
		DesiredStatus: ecstypes.DesiredStatusRunning,
		ServiceName:   aws.String(serviceName),
	})
	if err != nil || len(tasks.TaskArns) == 0 {
		return cache()
	}
	details, err := s.ecsClient.DescribeTasks(ctx, &ecs.DescribeTasksInput{
		Cluster: aws.String(cluster),
		Tasks:   tasks.TaskArns,
	})
	if err != nil {
		return cache()
	}

	zones := make(map[string]struct{})
	for i := range details.Tasks {
		task := &details.Tasks[i]
		if task.AvailabilityZone != nil && *task.AvailabilityZone != "" {
			zones[*task.AvailabilityZone] = struct{}{}
		}
		if task.TaskArn != nil {
			compute.TaskIDs = append(compute.TaskIDs, shortID(*task.TaskArn))
		}
	}
	for zone := range zones {
		compute.AvailabilityZones = append(compute.AvailabilityZones, zone)
	}
	sort.Strings(compute.AvailabilityZones)
	sort.Strings(compute.TaskIDs)
	compute.MultiAZ = len(compute.AvailabilityZones) > 1
	return cache()
}

func (s *Service) database(ctx context.Context) Database {
	s.mu.Lock()
	defer s.mu.Unlock()
	if time.Now().Before(s.databaseCacheTill) {
		return s.cachedDB
	}

	db := Database{Identifier: s.databaseID, Region: s.region, Role: "unavailable"}
	if s.rdsClient == nil {
		s.cachedDB = db
		s.databaseCacheTill = time.Now().Add(30 * time.Second)
		return db
	}

	output, err := s.rdsClient.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		DBInstanceIdentifier: aws.String(s.databaseID),
	})
	if err != nil || len(output.DBInstances) == 0 {
		s.cachedDB = db
		s.databaseCacheTill = time.Now().Add(30 * time.Second)
		return db
	}

	instance := output.DBInstances[0]
	db.AvailabilityZone = aws.ToString(instance.AvailabilityZone)
	db.Available = true
	db.Identifier = aws.ToString(instance.DBInstanceIdentifier)
	db.MultiAZ = aws.ToBool(instance.MultiAZ)
	db.ReadReplicaSource = aws.ToString(instance.ReadReplicaSourceDBInstanceIdentifier)
	db.SecondaryAvailabilityZone = aws.ToString(instance.SecondaryAvailabilityZone)
	db.Status = aws.ToString(instance.DBInstanceStatus)
	db.Role = "writer"
	if db.ReadReplicaSource != "" {
		db.Role = "read replica"
	}
	s.cachedDB = db
	s.databaseCacheTill = time.Now().Add(30 * time.Second)
	return db
}

func shortID(arn string) string {
	parts := strings.Split(arn, "/")
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}
