package config

import "os"

type Config struct {
	Env                     string
	Port                    string
	JWTSecret               string
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
