package proxy

import "github.com/gin-gonic/gin"

type ReportProxy struct{ handler gin.HandlerFunc }

func NewReportProxy(serviceURL string) *ReportProxy {
	return &ReportProxy{handler: New(serviceURL)}
}

func (p *ReportProxy) Handler() gin.HandlerFunc { return p.handler }
