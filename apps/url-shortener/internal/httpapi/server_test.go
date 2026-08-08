package httpapi

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aws-pilotlight-multi-region-dr/apps/url-shortener/internal/links"
)

type fakeStore struct {
	items map[string]links.Link
}

func newFakeStore() *fakeStore {
	return &fakeStore{items: make(map[string]links.Link)}
}

func (f *fakeStore) Ping(context.Context) error {
	return nil
}

func (f *fakeStore) Create(_ context.Context, slug, destinationURL string) (links.Link, error) {
	if _, exists := f.items[slug]; exists {
		return links.Link{}, links.ErrSlugExists
	}
	link := links.Link{ID: int64(len(f.items) + 1), Slug: slug, DestinationURL: destinationURL, CreatedAt: time.Now()}
	f.items[slug] = link
	return link, nil
}

func (f *fakeStore) Get(_ context.Context, slug string) (links.Link, error) {
	link, exists := f.items[slug]
	if !exists {
		return links.Link{}, sql.ErrNoRows
	}
	return link, nil
}

func (f *fakeStore) List(context.Context, int) ([]links.Link, error) {
	result := make([]links.Link, 0, len(f.items))
	for _, link := range f.items {
		result = append(result, link)
	}
	return result, nil
}

func TestCreateAndRedirect(t *testing.T) {
	handler := New(newFakeStore(), "operator-secret")
	body := `{"slug":"demo-link","destination_url":"https://example.com/recovered"}`
	request := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/links", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer operator-secret")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want %d; body=%s", response.Code, http.StatusCreated, response.Body.String())
	}

	request = httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/demo-link", nil)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusFound {
		t.Fatalf("redirect status = %d, want %d", response.Code, http.StatusFound)
	}
	if location := response.Header().Get("Location"); location != "https://example.com/recovered" {
		t.Fatalf("location = %q, want recovered URL", location)
	}
}

func TestCreateRequiresToken(t *testing.T) {
	handler := New(newFakeStore(), "operator-secret")
	request := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/links", strings.NewReader(`{"slug":"demo","destination_url":"https://example.com"}`))
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusUnauthorized)
	}
}

func TestCreateValidatesInput(t *testing.T) {
	handler := New(newFakeStore(), "operator-secret")
	tests := []struct {
		name string
		body string
	}{
		{name: "invalid slug", body: `{"slug":"no spaces","destination_url":"https://example.com"}`},
		{name: "invalid destination", body: `{"slug":"demo","destination_url":"file:///etc/passwd"}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequestWithContext(context.Background(), http.MethodPost, "/links", strings.NewReader(test.body))
			request.Header.Set("Authorization", "Bearer operator-secret")
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
			}
		})
	}
}

func TestListReturnsJSON(t *testing.T) {
	store := newFakeStore()
	store.items["demo"] = links.Link{ID: 1, Slug: "demo", DestinationURL: "https://example.com", CreatedAt: time.Now()}
	handler := New(store, "operator-secret")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, httptest.NewRequestWithContext(context.Background(), http.MethodGet, "/links", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	var result []links.Link
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(result) != 1 || result[0].Slug != "demo" {
		t.Fatalf("result = %#v, want demo link", result)
	}
}
