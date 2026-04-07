package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env                    string
	Port                   string
	GRPCPort               string
	DBHost                 string
	DBPort                 string
	DBName                 string
	DBUser                 string
	DBPassword             string
	RedisHost              string
	RedisPort              string
	RedisPass              string
	JWTSecret              string
	JWTExpiryHrs           int
	NotificationServiceURL string
	AppBaseURL             string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env:                    getEnv("ENV", "development"),
		Port:                   getEnv("PORT", "8081"),
		GRPCPort:               getEnv("GRPC_PORT", "50051"),
		DBHost:                 getEnv("DB_HOST", "localhost"),
		DBPort:                 getEnv("DB_PORT", "5432"),
		DBName:                 getEnv("DB_NAME", "ecocomply"),
		DBUser:                 getEnv("DB_USER", "postgres"),
		DBPassword:             getEnv("DB_PASSWORD", "secret"),
		RedisHost:              getEnv("REDIS_HOST", "localhost"),
		RedisPort:              getEnv("REDIS_PORT", "6379"),
		RedisPass:              getEnv("REDIS_PASS", ""),
		JWTSecret:              getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs:           expiry,
		NotificationServiceURL: getEnv("NOTIFICATION_SERVICE_URL", "http://notification-service:8086"),
		AppBaseURL:             getEnv("APP_BASE_URL", "http://localhost:3000"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
