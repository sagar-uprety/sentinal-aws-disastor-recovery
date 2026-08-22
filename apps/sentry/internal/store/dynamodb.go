package store

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/feature/dynamodb/attributevalue"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// narrow subset of the AWS SDK client this store needs; lets tests substitute a fake.
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

// on-wire shape of a check row: single-table pk/sk keys plus a TTL attribute DynamoDB uses to expire old rows.
type checkItem struct {
	PK string `dynamodbav:"pk"`
	SK string `dynamodbav:"sk"`
	Check
	ExpiresAt int64 `dynamodbav:"expires_at"`
}

// wires a DynamoDB-backed Store for one fixed target URL against the given table.
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

// queries checks since the cutoff for uptime; if none fall in that window it falls back to the single most recent check (0/0 uptime) so status still shows "last seen" instead of nothing.
func (d *DynamoDB) LatestStatuses(ctx context.Context, since time.Time) ([]TargetStatus, error) {
	// upper bound is nudged one second past now so a check written in this same second isn't excluded by the BETWEEN range.
	checks, err := d.query(ctx, d.target.URL, since, d.now().UTC().Add(time.Second), 0)
	if err != nil {
		return nil, err
	}
	if len(checks) == 0 {
		checks, err = d.query(ctx, d.target.URL, time.Time{}, time.Time{}, 1)
		if err != nil {
			return nil, err
		}
		if len(checks) == 0 {
			return []TargetStatus{}, nil
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

func (d *DynamoDB) Health(ctx context.Context) error {
	_, err := d.client.DescribeTable(ctx, &dynamodb.DescribeTableInput{TableName: aws.String(d.table)})
	if err != nil {
		return fmt.Errorf("describe table: %w", err)
	}
	return nil
}

// queries newest-first by sort key; a zero from/to means "no time bound", a positive limit means "single page, no pagination".
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
	// bounded History calls fetch one page directly; unbounded LatestStatuses calls page through everything in the window.
	if limit > 0 {
		page, err := d.client.Query(ctx, input)
		if err != nil {
			return nil, fmt.Errorf("query checks: %w", err)
		}
		return appendPage(checks, page.Items)
	}
	paginator := dynamodb.NewQueryPaginator(d.client, input)
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("query checks: %w", err)
		}
		checks, err = appendPage(checks, page.Items)
		if err != nil {
			return nil, err
		}
	}
	return checks, nil
}

// decodes one page of DynamoDB items into Checks, dropping the pk/sk/TTL envelope attributes.
func appendPage(checks []Check, items []map[string]types.AttributeValue) ([]Check, error) {
	var decoded []checkItem
	if err := attributevalue.UnmarshalListOfMaps(items, &decoded); err != nil {
		return nil, fmt.Errorf("unmarshal checks: %w", err)
	}
	for i := range decoded {
		checks = append(checks, decoded[i].Check)
	}
	return checks, nil
}

// partition key groups all of one target's checks together.
func targetPK(target string) string { return "TARGET#" + target }

// sort key is time-ordered (RFC3339Nano), so a Query naturally returns checks in chronological order.
func checkSK(checkedAt time.Time) string { return "CHECK#" + checkedAt.UTC().Format(time.RFC3339Nano) }
