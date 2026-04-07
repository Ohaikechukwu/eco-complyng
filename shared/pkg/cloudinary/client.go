package cloudinary

import (
	"context"
	"fmt"
	"io"
	"mime/multipart"

	"github.com/cloudinary/cloudinary-go/v2"
	"github.com/cloudinary/cloudinary-go/v2/api/uploader"
)

type Config struct {
	CloudName string
	APIKey    string
	APISecret string
	Folder    string
}

type UploadResult struct {
	PublicID string
	URL      string
	Bytes    int64
	Format   string
}

type Client struct {
	cld    *cloudinary.Cloudinary
	folder string
}

func NewClient(cfg Config) (*Client, error) {
	cld, err := cloudinary.NewFromParams(cfg.CloudName, cfg.APIKey, cfg.APISecret)
	if err != nil {
		return nil, fmt.Errorf("cloudinary init failed: %w", err)
	}
	return &Client{cld: cld, folder: cfg.Folder}, nil
}

// UploadFile uploads a multipart file (images).
func (c *Client) UploadFile(ctx context.Context, file multipart.File, filename string) (*UploadResult, error) {
	params := uploader.UploadParams{
		Folder:   c.folder,
		PublicID: filename,
	}
	result, err := c.cld.Upload.Upload(ctx, file, params)
	if err != nil {
		return nil, fmt.Errorf("cloudinary upload failed: %w", err)
	}
	return &UploadResult{
		PublicID: result.PublicID,
		URL:      result.SecureURL,
		Bytes:    int64(result.Bytes),
		Format:   result.Format,
	}, nil
}

// UploadPDF uploads a PDF file (reports).
func (c *Client) UploadPDF(ctx context.Context, file io.Reader, filename string) (*UploadResult, error) {
	params := uploader.UploadParams{
		Folder:       fmt.Sprintf("%s/reports", c.folder),
		PublicID:     filename,
		ResourceType: "raw", // PDFs must use "raw" resource type
	}
	result, err := c.cld.Upload.Upload(ctx, file, params)
	if err != nil {
		return nil, fmt.Errorf("cloudinary PDF upload failed: %w", err)
	}
	return &UploadResult{
		PublicID: result.PublicID,
		URL:      result.SecureURL,
		Bytes:    int64(result.Bytes),
		Format:   result.Format,
	}, nil
}

// DeleteFile removes a file from Cloudinary by its public ID.
func (c *Client) DeleteFile(ctx context.Context, publicID string) error {
	_, err := c.cld.Upload.Destroy(ctx, uploader.DestroyParams{PublicID: publicID})
	return err
}
