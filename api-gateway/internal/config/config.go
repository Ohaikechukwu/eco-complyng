package config

import (
	"os"
	"strings"
)

type Config struct {
	Env                     string
	Port                    string
	JWTSecret               string
	JWTIssuer               string
	JWTAudiences            []string
	CSRFCookieName          string
	CSRFHeaderName          string
	AllowedOrigins          string
	RedisHost               string
	RedisPort               string
	RedisPass               string
	AuthServiceURL          string
	InspectionServiceURL    string
	MediaServiceURL         string
	ReportServiceURL        string
	CollaborationServiceURL string
	NotificationServiceURL  string
	ExportServiceURL        string
}

func Load() *Config {
	return &Config{
		Env:                     getEnv("ENV", "development"),
		Port:                    getEnv("PORT", "8080"),
		JWTSecret:               getEnv("JWT_SECRET", "change-me"),
		JWTIssuer:               getEnv("JWT_ISSUER", "auth.ecocomply.ng"),
		JWTAudiences:            getCSVEnv("JWT_AUDIENCE", "api-gateway"),
		CSRFCookieName:          getEnv("CSRF_COOKIE_NAME", "csrf_token"),
		CSRFHeaderName:          getEnv("CSRF_HEADER_NAME", "X-CSRF-Token"),
		AllowedOrigins:          getEnv("ALLOWED_ORIGINS", "http://localhost:3000"),
		RedisHost:               getEnv("REDIS_HOST", "localhost"),
		RedisPort:               getEnv("REDIS_PORT", "6379"),
		RedisPass:               getEnv("REDIS_PASS", ""),
		AuthServiceURL:          getEnv("AUTH_SERVICE_URL", "http://localhost:8081"),
		InspectionServiceURL:    getEnv("INSPECTION_SERVICE_URL", "http://localhost:8082"),
		MediaServiceURL:         getEnv("MEDIA_SERVICE_URL", "http://localhost:8083"),
		ReportServiceURL:        getEnv("REPORT_SERVICE_URL", "http://localhost:8084"),
		CollaborationServiceURL: getEnv("COLLABORATION_SERVICE_URL", "http://localhost:8085"),
		NotificationServiceURL:  getEnv("NOTIFICATION_SERVICE_URL", "http://localhost:8086"),
		ExportServiceURL:        getEnv("EXPORT_SERVICE_URL", "http://localhost:8087"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getCSVEnv(key, fallback string) []string {
	value := getEnv(key, fallback)
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		result = append(result, part)
	}
	return result
}
