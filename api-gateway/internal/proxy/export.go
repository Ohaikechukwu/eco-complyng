package proxy

import "github.com/gin-gonic/gin"

type ExportProxy struct{ handler gin.HandlerFunc }

func NewExportProxy(serviceURL string) *ExportProxy {
	return &ExportProxy{handler: New(serviceURL)}
}

func (p *ExportProxy) Handler() gin.HandlerFunc { return p.handler }
