package store

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

type dynamodbAPI interface {
	DescribeTable(context.Context, *dynamodb.DescribeTableInput, ...func(*dynamodb.Options)) (*dynamodb.DescribeTableOutput, error)
	PutItem(context.Context, *dynamodb.PutItemInput, ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error)
	Query(context.Context, *dynamodb.QueryInput, ...func(*dynamodb.Options)) (*dynamodb.QueryOutput, error)
}

type DynamoDB struct {
	client dynamodbAPI
	now    func() time.Time
	table  string
	target Target
}

type checkItem struct {
	PK string `dynamodbav:"pk"`
	SK string `dynamodbav:"sk"`
	Check
	ExpiresAt int64 `dynamodbav:"expires_at"`
}

type eventItem struct {
	PK string `dynamodbav:"pk"`
	SK string `dynamodbav:"sk"`
	DrillEvent
}

func NewDynamoDB(client dynamodbAPI, table, targetURL string) *DynamoDB {
	return &DynamoDB{client: client, table: table, target: Target{URL: targetURL}, now: time.Now}
}

func (d *DynamoDB) ListTargets(context.Context) ([]Target, error) {
	return []Target{d.target}, nil
}

func (d *DynamoDB) RecordCheck(ctx context.Context, check Check) error {
	item, err := attributevalue.MarshalMap(checkItem{
		Check:     check,
		PK:        targetPK(check.TargetURL),
		SK:        checkSK(check.CheckedAt),
		ExpiresAt: check.CheckedAt.Add(Retention).Unix(),
	})
	if err != nil {
		return fmt.Errorf("marshal check: %w", err)
	}
	_, err = d.client.PutItem(ctx, &dynamodb.PutItemInput{TableName: aws.String(d.table), Item: item})
	if err != nil {
		return fmt.Errorf("put check: %w", err)
	}
	return nil
}

func (d *DynamoDB) LatestStatuses(ctx context.Context, since time.Time) ([]TargetStatus, error) {
	checks, err := d.query(ctx, d.target.URL, since, d.now().UTC().Add(time.Second), 0)
	if err != nil {
		return nil, err
	}
	if len(checks) == 0 {
		checks, err = d.query(ctx, d.target.URL, time.Time{}, time.Time{}, 1)
		if err != nil || len(checks) == 0 {
			return []TargetStatus{}, err
		}
		return []TargetStatus{statusFromChecks(checks[0], 0, 0)}, nil
	}
	up := 0
	for i := range checks {
		if checks[i].IsUp {
			up++
		}
	}
	return []TargetStatus{statusFromChecks(checks[0], up, len(checks))}, nil
}

func (d *DynamoDB) History(ctx context.Context, target string, limit int) ([]Check, error) {
	return d.query(ctx, target, time.Time{}, time.Time{}, int32(limit))
}

func (d *DynamoDB) ListEvents(ctx context.Context, limit int) ([]DrillEvent, error) {
	input := &dynamodb.QueryInput{
		TableName:              aws.String(d.table),
		KeyConditionExpression: aws.String("pk = :pk AND begins_with(sk, :prefix)"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":pk":     &types.AttributeValueMemberS{Value: "EVENTS"},
			":prefix": &types.AttributeValueMemberS{Value: "EVENT#"},
		},
		ScanIndexForward: aws.Bool(false),
		Limit:            aws.Int32(int32(limit)),
	}
	output, err := d.client.Query(ctx, input)
	if err != nil {
		return nil, fmt.Errorf("query events: %w", err)
	}
	var items []eventItem
	if err := attributevalue.UnmarshalListOfMaps(output.Items, &items); err != nil {
		return nil, fmt.Errorf("unmarshal events: %w", err)
	}
	events := make([]DrillEvent, 0, len(items))
	for _, item := range items {
		event := item.DrillEvent
		if event.Name == "" || event.Timestamp.IsZero() {
			var parseErr error
			event, parseErr = drillEventFromSK(item.SK)
			if parseErr != nil {
				return nil, parseErr
			}
		}
		events = append(events, event)
	}
	return events, nil
}

func (d *DynamoDB) Health(ctx context.Context) error {
	_, err := d.client.DescribeTable(ctx, &dynamodb.DescribeTableInput{TableName: aws.String(d.table)})
	if err != nil {
		return fmt.Errorf("describe table: %w", err)
	}
	return nil
}

func (d *DynamoDB) query(ctx context.Context, target string, from, to time.Time, limit int32) ([]Check, error) {
	values := map[string]types.AttributeValue{":pk": &types.AttributeValueMemberS{Value: targetPK(target)}}
	condition := "pk = :pk"
	if !from.IsZero() {
		condition += " AND sk BETWEEN :from AND :to"
		values[":from"] = &types.AttributeValueMemberS{Value: checkSK(from)}
		values[":to"] = &types.AttributeValueMemberS{Value: checkSK(to)}
	}
	input := &dynamodb.QueryInput{
		TableName:                 aws.String(d.table),
		KeyConditionExpression:    aws.String(condition),
		ExpressionAttributeValues: values,
		ScanIndexForward:          aws.Bool(false),
	}
	if limit > 0 {
		input.Limit = aws.Int32(limit)
	}

	checks := make([]Check, 0)
	if limit > 0 {
		page, err := d.client.Query(ctx, input)
		if err != nil {
			return nil, fmt.Errorf("query checks: %w", err)
		}
		var items []checkItem
		if err := attributevalue.UnmarshalListOfMaps(page.Items, &items); err != nil {
			return nil, fmt.Errorf("unmarshal checks: %w", err)
		}
		for i := range items {
			checks = append(checks, items[i].Check)
		}
		return checks, nil
	}
	paginator := dynamodb.NewQueryPaginator(d.client, input)
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("query checks: %w", err)
		}
		var items []checkItem
		if err := attributevalue.UnmarshalListOfMaps(page.Items, &items); err != nil {
			return nil, fmt.Errorf("unmarshal checks: %w", err)
		}
		for i := range items {
			checks = append(checks, items[i].Check)
		}
	}
	return checks, nil
}

func targetPK(target string) string { return "TARGET#" + target }

func checkSK(checkedAt time.Time) string { return "CHECK#" + checkedAt.UTC().Format(time.RFC3339Nano) }

func drillEventFromSK(sk string) (DrillEvent, error) {
	value, ok := strings.CutPrefix(sk, "EVENT#")
	if !ok {
		return DrillEvent{}, fmt.Errorf("invalid event sort key %q", sk)
	}
	timestamp, name, ok := strings.Cut(value, "#")
	if !ok || name == "" {
		return DrillEvent{}, fmt.Errorf("invalid event sort key %q", sk)
	}
	parsed, err := time.Parse(time.RFC3339Nano, timestamp)
	if err != nil {
		return DrillEvent{}, fmt.Errorf("invalid event sort key %q: %w", sk, err)
	}
	return DrillEvent{Name: name, Timestamp: parsed}, nil
}
