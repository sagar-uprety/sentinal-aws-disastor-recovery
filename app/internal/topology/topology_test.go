package topology

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	"github.com/aws/aws-sdk-go-v2/service/ecs/types"
)

type fakeECS struct{}

func (fakeECS) DescribeServices(context.Context, *ecs.DescribeServicesInput, ...func(*ecs.Options)) (*ecs.DescribeServicesOutput, error) {
	return &ecs.DescribeServicesOutput{Services: []types.Service{{DesiredCount: 2, RunningCount: 2}}}, nil
}

func (fakeECS) ListTasks(context.Context, *ecs.ListTasksInput, ...func(*ecs.Options)) (*ecs.ListTasksOutput, error) {
	return &ecs.ListTasksOutput{TaskArns: []string{"arn:aws:ecs:eu-central-1:123:task/cluster/task-b", "arn:aws:ecs:eu-central-1:123:task/cluster/task-a"}}, nil
}

func (fakeECS) DescribeTasks(context.Context, *ecs.DescribeTasksInput, ...func(*ecs.Options)) (*ecs.DescribeTasksOutput, error) {
	return &ecs.DescribeTasksOutput{Tasks: []types.Task{
		{AvailabilityZone: aws.String("eu-central-1b"), TaskArn: aws.String("arn:aws:ecs:eu-central-1:123:task/cluster/task-b")},
		{AvailabilityZone: aws.String("eu-central-1a"), TaskArn: aws.String("arn:aws:ecs:eu-central-1:123:task/cluster/task-a")},
	}}, nil
}

func TestSnapshotWithoutAWSMetadata(t *testing.T) {
	t.Setenv("ECS_CONTAINER_METADATA_URI_V4", "")

	snapshot := New(context.Background(), "local", "").Snapshot(context.Background())
	if snapshot.Application.Region != "local" {
		t.Fatalf("application region = %q, want local", snapshot.Application.Region)
	}
	if snapshot.Database.Available {
		t.Fatal("database should be unavailable without configured AWS topology")
	}
}

func TestShortID(t *testing.T) {
	got := shortID("arn:aws:ecs:eu-central-1:123456789012:task/cluster/task-id")
	if got != "task-id" {
		t.Fatalf("shortID = %q, want task-id", got)
	}
}

func TestComputeReportsTaskCountAndAZSpread(t *testing.T) {
	service := &Service{ecsClient: fakeECS{}, region: "eu-central-1"}

	compute := service.compute(context.Background(), "cluster", "sentinel")

	if !compute.Available || !compute.MultiAZ {
		t.Fatalf("compute availability = %v, multi-AZ = %v, want both true", compute.Available, compute.MultiAZ)
	}
	if compute.DesiredCount != 2 || compute.RunningCount != 2 {
		t.Fatalf("compute counts = %d/%d, want 2/2", compute.RunningCount, compute.DesiredCount)
	}
	if len(compute.AvailabilityZones) != 2 || compute.AvailabilityZones[0] != "eu-central-1a" || compute.AvailabilityZones[1] != "eu-central-1b" {
		t.Fatalf("availability zones = %v", compute.AvailabilityZones)
	}
	if len(compute.TaskIDs) != 2 || compute.TaskIDs[0] != "task-a" || compute.TaskIDs[1] != "task-b" {
		t.Fatalf("task IDs = %v", compute.TaskIDs)
	}
}
