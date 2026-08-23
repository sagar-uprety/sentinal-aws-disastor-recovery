package store

import (
	"context"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// captures the inputs DynamoDB store methods send and returns canned items, so tests assert on the query shape without a real table.
type fakeDynamoDB struct {
	putInput   *dynamodb.PutItemInput
	queryInput *dynamodb.QueryInput
	items      []map[string]types.AttributeValue
}

func (f *fakeDynamoDB) DescribeTable(context.Context, *dynamodb.DescribeTableInput, ...func(*dynamodb.Options)) (*dynamodb.DescribeTableOutput, error) {
	return &dynamodb.DescribeTableOutput{}, nil
}
func (f *fakeDynamoDB) PutItem(_ context.Context, input *dynamodb.PutItemInput, _ ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error) {
	f.putInput = input
	return &dynamodb.PutItemOutput{}, nil
}
func (f *fakeDynamoDB) Query(_ context.Context, input *dynamodb.QueryInput, _ ...func(*dynamodb.Options)) (*dynamodb.QueryOutput, error) {
	f.queryInput = input
	return &dynamodb.QueryOutput{Items: f.items}, nil
}

func TestDynamoDBRecordUsesCompositeKeyAndTTL(t *testing.T) {
	client := &fakeDynamoDB{}
	dataStore := NewDynamoDB(client, "checks", "https://example.com/healthz")
	checkedAt := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	if err := dataStore.RecordCheck(context.Background(), Check{TargetURL: "https://example.com/healthz", CheckedAt: checkedAt, IsUp: true}); err != nil {
		t.Fatalf("record check: %v", err)
	}
	var item checkItem
	if err := attributevalue.UnmarshalMap(client.putInput.Item, &item); err != nil {
		t.Fatalf("unmarshal item: %v", err)
	}
	if item.PK != "TARGET#https://example.com/healthz" || item.SK != "CHECK#2026-07-26T12:00:00.000000000Z" || item.ExpiresAt != checkedAt.Add(Retention).Unix() {
		t.Fatalf("item = %#v", item)
	}
}

// a whole-second check must still sort below a fractional one in the same second,
// which the old trailing-zero-trimming format got backwards.
func TestCheckSKSortsWholeSecondsBeforeFractional(t *testing.T) {
	whole := checkSK(time.Date(2026, 7, 26, 12, 0, 5, 0, time.UTC))
	fractional := checkSK(time.Date(2026, 7, 26, 12, 0, 5, 500000000, time.UTC))
	if whole >= fractional {
		t.Fatalf("sort key ordering is inverted: %q >= %q", whole, fractional)
	}
}

func TestDynamoDBHistoryUsesDescendingQuery(t *testing.T) {
	client := &fakeDynamoDB{}
	dataStore := NewDynamoDB(client, "checks", "https://example.com/healthz")
	checks, err := dataStore.History(context.Background(), "https://example.com/healthz", 25)
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(checks) != 0 || aws.ToString(client.queryInput.KeyConditionExpression) != "pk = :pk" || aws.ToBool(client.queryInput.ScanIndexForward) || aws.ToInt32(client.queryInput.Limit) != 25 {
		t.Fatalf("query input = %#v", client.queryInput)
	}
}

// both fixture checks fall inside the 24h window (one up, one down), so the resulting 50% uptime proves both were counted.
func TestDynamoDBLatestStatusQueriesTimeRange(t *testing.T) {
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	items := make([]map[string]types.AttributeValue, 0, 2)
	for _, check := range []Check{
		{TargetURL: "https://example.com/healthz", CheckedAt: now, IsUp: true, ResponseMs: 20},
		{TargetURL: "https://example.com/healthz", CheckedAt: now.Add(-time.Hour), IsUp: false, ResponseMs: 40},
	} {
		item, err := attributevalue.MarshalMap(checkItem{Check: check, PK: targetPK(check.TargetURL), SK: checkSK(check.CheckedAt)})
		if err != nil {
			t.Fatalf("marshal fixture: %v", err)
		}
		items = append(items, item)
	}
	client := &fakeDynamoDB{items: items}
	dataStore := NewDynamoDB(client, "checks", "https://example.com/healthz")
	dataStore.now = func() time.Time { return now }
	statuses, err := dataStore.LatestStatuses(context.Background(), now.Add(-24*time.Hour))
	if err != nil {
		t.Fatalf("latest statuses: %v", err)
	}
	if len(statuses) != 1 || statuses[0].UptimePct != 50 || !statuses[0].IsUp {
		t.Fatalf("statuses = %#v", statuses)
	}
	if aws.ToString(client.queryInput.KeyConditionExpression) != "pk = :pk AND sk BETWEEN :from AND :to" || aws.ToBool(client.queryInput.ScanIndexForward) {
		t.Fatalf("query input = %#v", client.queryInput)
	}
}
