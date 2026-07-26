package httpapi

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"sentinel-aws-dr/workload/internal/links"
)

const indexHTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Short Route</title>
<style>
:root{color-scheme:light;--ink:#102a43;--muted:#627d98;--paper:#f4f8fb;--card:#fff;--line:#bcccdc;--blue:#1d4ed8;--orange:#f97316}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font-family:ui-sans-serif,system-ui,sans-serif}main{width:min(920px,calc(100% - 32px));margin:0 auto;padding:64px 0}header{display:grid;grid-template-columns:1fr auto;gap:32px;align-items:end;border-bottom:2px solid var(--ink);padding-bottom:24px}h1{font-size:clamp(3rem,10vw,7rem);line-height:.8;letter-spacing:-.08em;margin:0}.route{font:700 12px ui-monospace,monospace;text-transform:uppercase;letter-spacing:.12em;color:var(--blue)}.arrow{font-size:4rem;color:var(--orange)}section{background:var(--card);border:1px solid var(--line);margin-top:24px;padding:24px}form{display:grid;grid-template-columns:1fr 1fr;gap:16px}label{display:grid;gap:7px;font-size:13px;font-weight:700}label:first-child{grid-column:1/-1}input{width:100%;border:1px solid var(--line);padding:12px;font:inherit;background:#fff}input:focus{outline:3px solid #bfdbfe;border-color:var(--blue)}button{border:0;background:var(--blue);color:#fff;padding:13px 18px;font-weight:800;cursor:pointer;align-self:end}button:hover{background:#1e40af}.message{min-height:24px;color:var(--muted)}ul{list-style:none;padding:0;margin:0}li{display:grid;grid-template-columns:140px 1fr;gap:18px;padding:14px 0;border-top:1px solid var(--line)}li a{font:700 14px ui-monospace,monospace;color:var(--blue)}li span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--muted)}@media(max-width:640px){main{padding:36px 0}header,form{grid-template-columns:1fr}.arrow{display:none}li{grid-template-columns:1fr;gap:5px}}
</style>
</head>
<body><main><header><div><div class="route">Database-backed drill workload</div><h1>Short<br>Route</h1></div><div class="arrow">↗</div></header>
<section><form id="create"><label>Destination URL<input name="destination_url" type="url" required placeholder="https://example.com/path"></label><label>Short name<input name="slug" required pattern="[a-zA-Z0-9_-]{3,32}" placeholder="demo-link"></label><label>Operator token<input name="token" type="password" required autocomplete="off"></label><button>Create short link</button></form><p class="message" id="message" aria-live="polite"></p></section>
<section><div class="route">Recent routes</div><ul id="links"></ul></section></main>
<script>
const list=document.querySelector('#links'),message=document.querySelector('#message');
async function load(){const response=await fetch('/links');const links=await response.json();list.replaceChildren(...links.map(link=>{const item=document.createElement('li'),short=document.createElement('a'),destination=document.createElement('span');short.href='/'+link.slug;short.textContent='/'+link.slug;destination.textContent=link.destination_url;item.append(short,destination);return item}))}
document.querySelector('#create').addEventListener('submit',async event=>{event.preventDefault();message.textContent='Creating route...';const data=new FormData(event.currentTarget),response=await fetch('/links',{method:'POST',headers:{'Authorization':'Bearer '+data.get('token'),'Content-Type':'application/json'},body:JSON.stringify({slug:data.get('slug'),destination_url:data.get('destination_url')})});const body=await response.json();message.textContent=response.ok?'Created /'+body.slug:body.error;response.ok&&load()});
load().catch(()=>{message.textContent='Could not load routes.'});
</script></body></html>`

var slugPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{3,32}$`)

type store interface {
	Ping(context.Context) error
	Create(context.Context, string, string) (links.Link, error)
	Get(context.Context, string) (links.Link, error)
	List(context.Context, int) ([]links.Link, error)
}

type server struct {
	store store
	token string
}

func New(store store, token string) http.Handler {
	s := &server{store: store, token: token}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /links", s.list)
	mux.HandleFunc("POST /links", s.create)
	mux.HandleFunc("GET /{$}", s.index)
	mux.HandleFunc("GET /{slug}", s.redirect)
	return mux
}

func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) create(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r.Header.Get("Authorization")) {
		writeError(w, http.StatusUnauthorized, "valid bearer token required")
		return
	}
	var input struct {
		DestinationURL string `json:"destination_url"`
		Slug           string `json:"slug"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		writeError(w, http.StatusBadRequest, "body must contain one JSON object")
		return
	}
	if !slugPattern.MatchString(input.Slug) {
		writeError(w, http.StatusBadRequest, "slug must be 3-32 letters, numbers, underscores, or hyphens")
		return
	}
	if !validDestination(input.DestinationURL) {
		writeError(w, http.StatusBadRequest, "destination_url must be an HTTP or HTTPS URL")
		return
	}
	link, err := s.store.Create(r.Context(), input.Slug, input.DestinationURL)
	if errors.Is(err, links.ErrSlugExists) {
		writeError(w, http.StatusConflict, "slug already exists")
		return
	}
	if err != nil {
		slog.Error("create link failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusCreated, link)
}

func (s *server) list(w http.ResponseWriter, r *http.Request) {
	result, err := s.store.List(r.Context(), 50)
	if err != nil {
		slog.Error("list links failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *server) redirect(w http.ResponseWriter, r *http.Request) {
	link, err := s.store.Get(r.Context(), r.PathValue("slug"))
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "short link not found")
		return
	}
	if err != nil {
		slog.Error("get link failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	http.Redirect(w, r, link.DestinationURL, http.StatusFound)
}

func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if _, err := io.WriteString(w, indexHTML); err != nil {
		slog.Error("write index failed", "error", err)
	}
}

func (s *server) authorized(header string) bool {
	provided, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || len(provided) != len(s.token) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(s.token)) == 1
}

func validDestination(raw string) bool {
	parsed, err := url.ParseRequestURI(raw)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" && parsed.User == nil
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("encode response failed", "error", err)
	}
}
