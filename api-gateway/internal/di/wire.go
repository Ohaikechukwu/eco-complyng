package di

import (
	"fmt"

	"github.com/ecocomply/api-gateway/internal/config"
	"github.com/ecocomply/api-gateway/internal/proxy"
	sharedredis "github.com/ecocomply/shared/pkg/redis"
	"github.com/redis/go-redis/v9"
)

type Container struct {
	Config *config.Config
	Redis  *redis.Client

	AuthProxy           *proxy.AuthProxy
	InspectionProxy     *proxy.InspectionProxy
	MediaProxy          *proxy.MediaProxy
	ReportProxy         *proxy.ReportProxy
	CollaborationProxy  *proxy.CollaborationProxy
	NotificationProxy   *proxy.NotificationProxy
	ExportProxy         *proxy.ExportProxy
}

func NewContainer(cfg *config.Config) (*Container, error) {
	rdb, err := sharedredis.Connect(sharedredis.Config{
		Host:     cfg.RedisHost,
		Port:     cfg.RedisPort,
		Password: cfg.RedisPass,
	})
	if err != nil {
		return nil, fmt.Errorf("redis: %w", err)
	}

	return &Container{
		Config:              cfg,
		Redis:               rdb,
		AuthProxy:           proxy.NewAuthProxy(cfg.AuthServiceURL),
		InspectionProxy:     proxy.NewInspectionProxy(cfg.InspectionServiceURL),
		MediaProxy:          proxy.NewMediaProxy(cfg.MediaServiceURL),
		ReportProxy:         proxy.NewReportProxy(cfg.ReportServiceURL),
		CollaborationProxy:  proxy.NewCollaborationProxy(cfg.CollaborationServiceURL),
		NotificationProxy:   proxy.NewNotificationProxy(cfg.NotificationServiceURL),
		ExportProxy:         proxy.NewExportProxy(cfg.ExportServiceURL),
	}, nil
}
