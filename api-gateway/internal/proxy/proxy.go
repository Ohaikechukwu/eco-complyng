package proxy

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/rs/zerolog/log"
)

// New creates a reverse proxy handler for the given target URL.
// stripPrefix is the gateway prefix to strip before forwarding.
// e.g. /api/v1/auth/login → strip nothing → /api/v1/auth/login
func New(targetURL string) gin.HandlerFunc {
	target, err := url.Parse(targetURL)
	if err != nil {
		log.Fatal().Err(err).Str("target", targetURL).Msg("invalid proxy target")
	}

	rp := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = target.Scheme
			req.URL.Host = target.Host
			req.Host = target.Host
			// Forward the real client IP
			if clientIP := req.Header.Get("X-Forwarded-For"); clientIP == "" {
				req.Header.Set("X-Forwarded-For", req.RemoteAddr)
			}
		},
		Transport: &http.Transport{
			ResponseHeaderTimeout: 30 * time.Second,
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			log.Error().Err(err).Str("target", targetURL).Msg("proxy error")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			w.Write([]byte(`{"success":false,"error":"service temporarily unavailable"}`))
		},
	}

	return func(c *gin.Context) {
		rp.ServeHTTP(c.Writer, c.Request)
	}
}
