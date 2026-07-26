package topology

import (
	"context"
	"sort"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	ecstypes "github.com/aws/aws-sdk-go-v2/service/ecs/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
)

type RegionConfig struct {
	Region             string
	ECSCluster         string
	ECSService         string
	DatabaseIdentifier string
}

type Database struct {
	AvailabilityZone          string `json:"availability_zone"`
	Identifier                string `json:"identifier"`
	ReadReplicaSource         string `json:"read_replica_source"`
	Region                    string `json:"region"`
	Role                      string `json:"role"`
	SecondaryAvailabilityZone string `json:"secondary_availability_zone"`
	Status                    string `json:"status"`
	MultiAZ                   bool   `json:"multi_az"`
	Available                 bool   `json:"available"`
}

type Compute struct {
	Name              string   `json:"name"`
	Region            string   `json:"region"`
	AvailabilityZones []string `json:"availability_zones"`
	TaskIDs           []string `json:"tasks"`
	DesiredCount      int32    `json:"desired"`
	RunningCount      int32    `json:"running"`
	Available         bool     `json:"available"`
}

type Region struct {
	Database Database `json:"database"`
	Region   string   `json:"region"`
	Compute  Compute  `json:"compute"`
}

type Snapshot struct {
	Regions []Region `json:"regions"`
}

type ecsAPI interface {
	DescribeServices(context.Context, *ecs.DescribeServicesInput, ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error)
	DescribeTasks(context.Context, *ecs.DescribeTasksInput, ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error)
	ListTasks(context.Context, *ecs.ListTasksInput, ...func(*ecs.Options)) (*ecs.ListTasksOutput, error)
}

type rdsAPI interface {
	DescribeDBInstances(context.Context, *rds.DescribeDBInstancesInput, ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error)
}

type regionReader struct {
	ecsClient ecsAPI
	rdsClient rdsAPI
	config    RegionConfig
}

type Service struct {
	regions []regionReader
}

func New(ctx context.Context, configs []RegionConfig) *Service {
	service := &Service{regions: make([]regionReader, 0, len(configs))}
	for _, regionConfig := range configs {
		reader := regionReader{config: regionConfig}
		if regionConfig.Region != "" {
			if cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(regionConfig.Region)); err == nil {
				reader.ecsClient = ecs.NewFromConfig(cfg)
				reader.rdsClient = rds.NewFromConfig(cfg)
			}
		}
		service.regions = append(service.regions, reader)
	}
	return service
}

func (s *Service) Snapshot(ctx context.Context) Snapshot {
	result := Snapshot{Regions: make([]Region, len(s.regions))}
	var wait sync.WaitGroup
	for i := range s.regions {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			reader := &s.regions[index]
			result.Regions[index] = Region{
				Region:   reader.config.Region,
				Compute:  reader.compute(ctx),
				Database: reader.database(ctx),
			}
		}(i)
	}
	wait.Wait()
	return result
}

func (r *regionReader) compute(ctx context.Context) Compute {
	result := Compute{
		Name: r.config.ECSService, Region: r.config.Region,
		AvailabilityZones: []string{}, TaskIDs: []string{},
	}
	if r.ecsClient == nil || r.config.ECSCluster == "" || r.config.ECSService == "" {
		return result
	}
	services, err := r.ecsClient.DescribeServices(ctx, &ecs.DescribeServicesInput{
		Cluster: aws.String(r.config.ECSCluster), Services: []string{r.config.ECSService},
	})
	if err != nil || len(services.Services) == 0 {
		return result
	}
	result.Available = len(services.Failures) == 0
	result.DesiredCount = services.Services[0].DesiredCount
	result.RunningCount = services.Services[0].RunningCount

	tasks, err := r.ecsClient.ListTasks(ctx, &ecs.ListTasksInput{
		Cluster: aws.String(r.config.ECSCluster), ServiceName: aws.String(r.config.ECSService),
		DesiredStatus: ecstypes.DesiredStatusRunning,
	})
	if err != nil || len(tasks.TaskArns) == 0 {
		return result
	}
	details, err := r.ecsClient.DescribeTasks(ctx, &ecs.DescribeTasksInput{
		Cluster: aws.String(r.config.ECSCluster), Tasks: tasks.TaskArns,
	})
	if err != nil {
		return result
	}
	zones := make(map[string]struct{})
	for i := range details.Tasks {
		zone := aws.ToString(details.Tasks[i].AvailabilityZone)
		if zone != "" {
			zones[zone] = struct{}{}
		}
		if task := shortID(aws.ToString(details.Tasks[i].TaskArn)); task != "" {
			result.TaskIDs = append(result.TaskIDs, task)
		}
	}
	for zone := range zones {
		result.AvailabilityZones = append(result.AvailabilityZones, zone)
	}
	sort.Strings(result.AvailabilityZones)
	sort.Strings(result.TaskIDs)
	return result
}

func (r *regionReader) database(ctx context.Context) Database {
	result := Database{Identifier: r.config.DatabaseIdentifier, Region: r.config.Region, Role: "unavailable"}
	if r.rdsClient == nil || r.config.DatabaseIdentifier == "" {
		return result
	}
	output, err := r.rdsClient.DescribeDBInstances(ctx, &rds.DescribeDBInstancesInput{
		DBInstanceIdentifier: aws.String(r.config.DatabaseIdentifier),
	})
	if err != nil || len(output.DBInstances) == 0 {
		return result
	}
	instance := output.DBInstances[0]
	result.AvailabilityZone = aws.ToString(instance.AvailabilityZone)
	result.Identifier = aws.ToString(instance.DBInstanceIdentifier)
	result.MultiAZ = aws.ToBool(instance.MultiAZ)
	result.ReadReplicaSource = aws.ToString(instance.ReadReplicaSourceDBInstanceIdentifier)
	result.SecondaryAvailabilityZone = aws.ToString(instance.SecondaryAvailabilityZone)
	result.Status = aws.ToString(instance.DBInstanceStatus)
	result.Available = result.Status == "available"
	result.Role = "writer"
	if result.ReadReplicaSource != "" {
		result.Role = "read replica"
	}
	return result
}

func shortID(arn string) string {
	for i := len(arn) - 1; i >= 0; i-- {
		if arn[i] == '/' {
			return arn[i+1:]
		}
	}
	return arn
}
