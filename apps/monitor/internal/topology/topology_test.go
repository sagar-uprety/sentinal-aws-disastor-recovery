package topology

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	ecstypes "github.com/aws/aws-sdk-go-v2/service/ecs/types"
	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
)

// canned ECS responses: one service at 2/2, two tasks split across two AZs (deliberately out of order to check the sort).
type fakeECS struct{}

func (fakeECS) DescribeServices(context.Context, *ecs.DescribeServicesInput, ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
	return &ecs.DescribeServicesOutput{Services: []ecstypes.Service{{DesiredCount: 2, RunningCount: 2}}}, nil
}
func (fakeECS) ListTasks(context.Context, *ecs.ListTasksInput, ...func(*ecs.Options)) (*ecs.ListTasksOutput, error) {
	return &ecs.ListTasksOutput{TaskArns: []string{"arn:task/task-b", "arn:task/task-a"}}, nil
}
func (fakeECS) DescribeTasks(context.Context, *ecs.DescribeTasksInput, ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error) {
	return &ecs.DescribeTasksOutput{Tasks: []ecstypes.Task{
		{AvailabilityZone: aws.String("eu-west-1b"), TaskArn: aws.String("arn:task/task-b")},
		{AvailabilityZone: aws.String("eu-west-1a"), TaskArn: aws.String("arn:task/task-a")},
	}}, nil
}

// canned RDS response; replica toggles whether the instance reports a replication source (drives the writer/read-replica role split).
type fakeRDS struct{ replica bool }

func (f fakeRDS) DescribeDBInstances(context.Context, *rds.DescribeDBInstancesInput, ...func(*rds.Options)) (*rds.DescribeDBInstancesOutput, error) {
	instance := rdstypes.DBInstance{
		DBInstanceIdentifier: aws.String("database"), DBInstanceStatus: aws.String("available"),
		AvailabilityZone: aws.String("eu-west-1a"), MultiAZ: aws.Bool(true),
	}
	if f.replica {
		instance.ReadReplicaSourceDBInstanceIdentifier = aws.String("prod-database")
	}
	return &rds.DescribeDBInstancesOutput{DBInstances: []rdstypes.DBInstance{instance}}, nil
}

// builds a Service directly from fake region readers (bypassing New/AWS config) to check per-region compute+database aggregation.
func TestSnapshotQueriesExplicitRegions(t *testing.T) {
	service := &Service{regions: []regionReader{
		{config: RegionConfig{Region: "eu-west-1", ECSCluster: "prod", ECSService: "workload", DatabaseIdentifier: "prod-db"}, ecsClient: fakeECS{}, rdsClient: fakeRDS{}},
		{config: RegionConfig{Region: "eu-central-1", ECSCluster: "dr", ECSService: "workload", DatabaseIdentifier: "dr-db"}, ecsClient: fakeECS{}, rdsClient: fakeRDS{replica: true}},
	}}
	snapshot := service.Snapshot(context.Background())
	if len(snapshot.Regions) != 2 || snapshot.Regions[0].Region != "eu-west-1" || snapshot.Regions[1].Region != "eu-central-1" {
		t.Fatalf("regions = %#v", snapshot.Regions)
	}
	compute := snapshot.Regions[0].Compute
	if !compute.Available || compute.DesiredCount != 2 || compute.RunningCount != 2 || len(compute.TaskIDs) != 2 || len(compute.AvailabilityZones) != 2 {
		t.Fatalf("compute = %#v", compute)
	}
	if snapshot.Regions[0].Database.Role != "writer" || snapshot.Regions[1].Database.Role != "read replica" {
		t.Fatalf("database roles = %q, %q", snapshot.Regions[0].Database.Role, snapshot.Regions[1].Database.Role)
	}
}

// a nil region config list must still produce an empty (never nil) Regions slice, so callers can safely range over it.
func TestSnapshotWithoutConfiguredAWS(t *testing.T) {
	snapshot := New(context.Background(), nil).Snapshot(context.Background())
	if snapshot.Regions == nil || len(snapshot.Regions) != 0 {
		t.Fatalf("regions = %#v, want empty array", snapshot.Regions)
	}
}

func TestNewMockReplaysSnapshotWithoutCallingAWS(t *testing.T) {
	want := Snapshot{Regions: []Region{{Region: "eu-central-1", Database: Database{Role: "writer"}}}}
	service := NewMock(want)
	got := service.Snapshot(context.Background())
	if len(got.Regions) != 1 || got.Regions[0].Region != "eu-central-1" || got.Regions[0].Database.Role != "writer" {
		t.Fatalf("Snapshot() = %#v, want %#v", got, want)
	}
}

func TestShortID(t *testing.T) {
	if got := shortID("arn:aws:ecs:eu-west-1:123:task/cluster/task-id"); got != "task-id" {
		t.Fatalf("shortID = %q", got)
	}
}
