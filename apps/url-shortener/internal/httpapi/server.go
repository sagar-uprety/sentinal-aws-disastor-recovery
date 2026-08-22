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

	"aws-pilotlight-multi-region-dr/apps/url-shortener/internal/links"
)

// single-file UI (inline CSS/JS, no build step) served at GET /; talks to the JSON API below via fetch.
const indexHTML = `<!doctype html>
	<html lang="en">
	<head>
	<meta charset="utf-8">
	<meta name="viewport" content="width=device-width,initial-scale=1">
	<title>URL Shortener</title>
	<link rel="preconnect" href="https://fonts.googleapis.com">
	<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
	<link href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;600;700&family=Fredoka:wght@400;500;600;700&display=swap" rel="stylesheet">
	<style>
	*{box-sizing:border-box;margin:0;padding:0}
	:root{--red:#ed1c24;--yellow:#ffd500;--blue:#0051ba;--green:#00a651;--ink:#1a1a2e;--bg:#f5f0e1;--card:#fff;--line:#d4c9b0;--shadow:rgba(0,0,0,.15)}
	body{background:var(--bg);font-family:'Barlow',sans-serif;color:var(--ink);min-height:100vh;padding:32px 16px}
	main{max-width:880px;margin:0 auto}
	header{text-align:center;padding:32px 0;position:relative}
	.tag{font:700 11px/1 'Barlow',sans-serif;text-transform:uppercase;letter-spacing:.15em;color:var(--blue);margin-bottom:8px}
	h1{font-family:'Fredoka',sans-serif;font-weight:700;font-size:clamp(2.2rem,9vw,4.2rem);line-height:1;color:var(--ink);letter-spacing:-.02em}
	.card{background:var(--card);border:4px solid var(--line);border-radius:16px;padding:28px;margin-top:24px;box-shadow:0 4px 12px var(--shadow)}
	.card-title{font-family:'Fredoka',sans-serif;font-weight:600;font-size:14px;text-transform:uppercase;letter-spacing:.08em;color:var(--blue);margin-bottom:20px;display:flex;align-items:center;gap:10px}
	.card-title::before{content:'';display:inline-block;width:16px;height:16px;border-radius:4px;background:var(--blue)}
	form{display:grid;grid-template-columns:1fr 1fr;gap:16px}
	label{display:grid;gap:6px;font-size:13px;font-weight:700;color:#444}
	label:first-child{grid-column:1/-1}
	input{width:100%;border:3px solid var(--line);border-radius:10px;padding:12px 14px;font:inherit;font-size:15px;background:#faf8f2;transition:border-color .15s}
	input:focus{outline:none;border-color:var(--blue);background:#fff}
	.btn{grid-column:1/-1;display:inline-flex;align-items:center;justify-content:center;gap:6px;border:0;background:var(--blue);color:#fff;font-family:'Fredoka',sans-serif;font-weight:600;font-size:15px;padding:13px 28px;border-radius:12px;cursor:pointer;transition:transform .1s,box-shadow .1s;box-shadow:0 4px 0 #003a85}
	.btn:hover{transform:translateY(-2px);box-shadow:0 6px 0 #003a85}
	.btn:active{transform:translateY(2px);box-shadow:0 1px 0 #003a85}
	.message{min-height:28px;font-size:14px;color:#666;margin-top:12px;text-align:center;font-weight:600}
	.message.ok{color:var(--green)}
	.message.err{color:var(--red)}
	ul{list-style:none;padding:0;margin:0}
	li{display:grid;grid-template-columns:140px 1fr auto;gap:14px;align-items:center;padding:14px 0;border-top:3px solid #eee}
	li:first-child{border-top:0}
	li a{font-family:'Fredoka',sans-serif;font-weight:600;font-size:16px;color:var(--blue);text-decoration:none;background:#eef4ff;padding:4px 12px;border-radius:8px;transition:background .15s}
	li a:hover{background:#dde8ff}
	li .dest{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#666;font-size:13px;font-weight:600}
	li .slug{font-size:11px;color:#888;font-weight:600;text-align:right}
	@media(max-width:640px){body{padding:16px 12px}.card{padding:20px}form{grid-template-columns:1fr}li{grid-template-columns:1fr;gap:8px}}
	</style>
	</head>
	<body><main><header><div class="tag">Disaster recovery drill workload</div><h1>URL Shortener</h1></header>
	<div class="card"><div class="card-title">New short link</div><form id="create"><label>Destination URL<input name="destination_url" type="url" required placeholder="https://example.com/path"></label><label>Short name<input name="slug" required pattern="[a-zA-Z0-9_-]{3,32}" placeholder="demo-link" maxlength="32"></label><label>Operator token<input name="token" type="password" required autocomplete="off" title="Only the project operator can create links. Ask the operator for this token."></label><button class="btn" type="submit">+ Create link</button></form><div class="message" id="message" aria-live="polite"></div></div>
	<div class="card"><div class="card-title">Recent links</div><ul id="links"><li style="grid-template-columns:1fr;text-align:center;color:#888;font-weight:600;padding:20px 0;border:0">Loading links...</li></ul></div></main>
	<script>
	const list=document.querySelector('#links'),msg=document.querySelector('#message');
	async function load(){const r=await fetch('/links');const links=await r.json();if(!links.length){list.innerHTML='<li style="grid-template-columns:1fr;text-align:center;color:#888;font-weight:600;padding:20px 0;border:0">No links yet. Create one!</li>';return}list.innerHTML=links.map(l=>'<li><a href="/'+l.slug+'">/'+l.slug+'</a><span class="dest">'+esc(l.destination_url)+'</span><span class="slug">'+ago(l.created_at)+'</span></li>').join('')}
	function esc(v){return String(v||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'})[c])}
	function ago(t){const s=Math.floor((Date.now()-new Date(t).getTime())/1000);if(s<10)return'just now';if(s<60)return s+'s ago';const m=Math.floor(s/60);return m<60?m+'m ago':Math.floor(m/60)+'h ago'}
	document.querySelector('#create').addEventListener('submit',async e=>{e.preventDefault();msg.textContent='Creating link...';msg.className='message';const d=new FormData(e.currentTarget);try{const r=await fetch('/links',{method:'POST',headers:{'Authorization':'Bearer '+d.get('token'),'Content-Type':'application/json'},body:JSON.stringify({slug:d.get('slug'),destination_url:d.get('destination_url')})});const b=await r.json();r.ok?(msg.textContent='Created /'+b.slug+'  |  '+b.destination_url,msg.className='message ok',load()):(msg.textContent=b.error,msg.className='message err')}catch(e){msg.textContent='Network error',msg.className='message err'}});
	load();
	</script></body></html>`

var slugPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{3,32}$`)

// narrow persistence dependency the server needs; implemented by links.Store, letting tests substitute a fake.
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

// builds the full HTTP handler: health, link CRUD/redirect, and the static index page.
func New(store store, token string) http.Handler {
	s := &server{store: store, token: token}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /links", s.list)
	mux.HandleFunc("POST /links", s.create)
	// "/{$}" matches only the exact root path, so the "/{slug}" wildcard below never swallows it.
	mux.HandleFunc("GET /{$}", s.index)
	mux.HandleFunc("GET /{slug}", s.redirect)
	return mux
}

// reports 503 when the database is unreachable; used by ECS/ALB health checks.
func (s *server) healthz(w http.ResponseWriter, r *http.Request) {
	if err := s.store.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// creates a short link behind the operator token; rejects malformed slugs/URLs and duplicate slugs.
func (s *server) create(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r.Header.Get("Authorization")) {
		writeError(w, http.StatusUnauthorized, "valid operator token required")
		return
	}
	var input struct {
		DestinationURL string `json:"destination_url"`
		Slug           string `json:"slug"`
	}
	// caps the body at 4KB and rejects unknown fields, so a malformed or oversized payload fails before touching the database.
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	// a second Decode call that doesn't hit io.EOF means there was trailing content after the first JSON value.
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
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

// returns the 50 most recently created links.
func (s *server) list(w http.ResponseWriter, r *http.Request) {
	result, err := s.store.List(r.Context(), 50)
	if err != nil {
		slog.Error("list links failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

// resolves a slug and 302s to its destination; 404s on an unknown slug.
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

// serves the single-page UI.
func (s *server) index(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	if _, err := io.WriteString(w, indexHTML); err != nil {
		slog.Error("write index failed", "error", err)
	}
}

// checks the bearer token in constant time to avoid leaking its value through response-time differences.
func (s *server) authorized(header string) bool {
	provided, ok := strings.CutPrefix(header, "Bearer ")
	// length is compared first because ConstantTimeCompare returns 0 for unequal lengths without comparing content; only the length leaks, never the token.
	if !ok || len(provided) != len(s.token) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(provided), []byte(s.token)) == 1
}

// rejects anything but a canonical http/https URL with no embedded credentials.
func validDestination(raw string) bool {
	parsed, err := url.ParseRequestURI(raw)
	return err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" && parsed.User == nil
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

// writes value as a JSON response body with the given status code.
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Error("encode response failed", "error", err)
	}
}
