package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env                  string
	Port                 string
	GRPCPort             string
	DBHost               string
	DBPort               string
	DBName               string
	DBUser               string
	DBPassword           string
	RedisHost            string
	RedisPort            string
	RedisPass            string
	JWTSecret            string
	JWTExpiryHrs         int
	CloudinaryCloudName  string
	CloudinaryAPIKey     string
	CloudinaryAPISecret  string
	TemplatePath         string
	InspectionServiceURL string
	MediaServiceURL      string
	AppBaseURL           string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env:                  getEnv("ENV", "development"),
		Port:                 getEnv("PORT", "8084"),
		GRPCPort:             getEnv("GRPC_PORT", "50054"),
		DBHost:               getEnv("DB_HOST", "localhost"),
		DBPort:               getEnv("DB_PORT", "5432"),
		DBName:               getEnv("DB_NAME", "ecocomply"),
		DBUser:               getEnv("DB_USER", "postgres"),
		DBPassword:           getEnv("DB_PASSWORD", "secret"),
		RedisHost:            getEnv("REDIS_HOST", "localhost"),
		RedisPort:            getEnv("REDIS_PORT", "6379"),
		RedisPass:            getEnv("REDIS_PASS", ""),
		JWTSecret:            getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs:         expiry,
		CloudinaryCloudName:  getEnv("CLOUDINARY_CLOUD_NAME", ""),
		CloudinaryAPIKey:     getEnv("CLOUDINARY_API_KEY", ""),
		CloudinaryAPISecret:  getEnv("CLOUDINARY_API_SECRET", ""),
		TemplatePath:         getEnv("TEMPLATE_PATH", "./internal/pdf/templates"),
		InspectionServiceURL: getEnv("INSPECTION_SERVICE_URL", "http://localhost:8082"),
		MediaServiceURL:      getEnv("MEDIA_SERVICE_URL", "http://localhost:8083"),
		AppBaseURL:           getEnv("APP_BASE_URL", "http://localhost:8080"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
