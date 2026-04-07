package config

import (
	"os"
	"strconv"
)

type Config struct {
	Env                 string
	Port                string
	GRPCPort            string
	DBHost              string
	DBPort              string
	DBName              string
	DBUser              string
	DBPassword          string
	RedisHost           string
	RedisPort           string
	RedisPass           string
	JWTSecret           string
	JWTExpiryHrs        int
	CloudinaryCloudName string
	CloudinaryAPIKey    string
	CloudinaryAPISecret string
}

func Load() *Config {
	expiry, _ := strconv.Atoi(getEnv("JWT_EXPIRY_HOURS", "24"))
	return &Config{
		Env:                 getEnv("ENV", "development"),
		Port:                getEnv("PORT", "8083"),
		GRPCPort:            getEnv("GRPC_PORT", "50053"),
		DBHost:              getEnv("DB_HOST", "localhost"),
		DBPort:              getEnv("DB_PORT", "5432"),
		DBName:              getEnv("DB_NAME", "ecocomply"),
		DBUser:              getEnv("DB_USER", "postgres"),
		DBPassword:          getEnv("DB_PASSWORD", "secret"),
		RedisHost:           getEnv("REDIS_HOST", "localhost"),
		RedisPort:           getEnv("REDIS_PORT", "6379"),
		RedisPass:           getEnv("REDIS_PASS", ""),
		JWTSecret:           getEnv("JWT_SECRET", "change-me"),
		JWTExpiryHrs:        expiry,
		CloudinaryCloudName: getEnv("CLOUDINARY_CLOUD_NAME", ""),
		CloudinaryAPIKey:    getEnv("CLOUDINARY_API_KEY", ""),
		CloudinaryAPISecret: getEnv("CLOUDINARY_API_SECRET", ""),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
