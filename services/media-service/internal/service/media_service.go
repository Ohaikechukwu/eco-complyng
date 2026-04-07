package service

import (
	"context"
	"fmt"
	"mime/multipart"
	"path/filepath"
	"strings"
	"time"

	"github.com/ecocomply/media-service/internal/domain"
	"github.com/ecocomply/media-service/internal/dto/request"
	"github.com/ecocomply/media-service/internal/dto/response"
	irepository "github.com/ecocomply/media-service/internal/repository/interface"
	"github.com/ecocomply/shared/pkg/cloudinary"
	"github.com/google/uuid"
)

const (
	maxFileSizeBytes = 10 * 1024 * 1024 // 10MB
)

var allowedMimeTypes = map[string]bool{
	"image/jpeg": true,
	"image/png":  true,
	"image/webp": true,
	"image/heic": true,
}

type MediaService struct {
	mediaRepo  irepository.MediaRepository
	cloudinary *cloudinary.Client
}

func NewMediaService(mediaRepo irepository.MediaRepository, cloudinary *cloudinary.Client) *MediaService {
	return &MediaService{mediaRepo: mediaRepo, cloudinary: cloudinary}
}

// Upload validates, uploads to Cloudinary, and persists the media record.
func (s *MediaService) Upload(
	ctx context.Context,
	userID uuid.UUID,
	fileHeader *multipart.FileHeader,
	req request.UploadMediaRequest,
) (*response.MediaResponse, error) {

	// 1. Validate file size
	if fileHeader.Size > maxFileSizeBytes {
		return nil, domain.ErrFileTooLarge
	}

	// 2. Validate mime type
	mimeType := fileHeader.Header.Get("Content-Type")
	if !allowedMimeTypes[mimeType] {
		return nil, domain.ErrUnsupportedType
	}

	// 3. Parse inspection ID
	inspectionID, err := uuid.Parse(req.InspectionID)
	if err != nil {
		return nil, domain.ErrInvalidInput
	}

	// 4. Open file
	file, err := fileHeader.Open()
	if err != nil {
		return nil, fmt.Errorf("failed to open file: %w", err)
	}
	defer file.Close()

	// 5. Build a unique Cloudinary filename
	ext := filepath.Ext(fileHeader.Filename)
	cloudinaryFilename := fmt.Sprintf("%s_%s%s", inspectionID, uuid.New().String(), ext)

	// 6. Upload to Cloudinary
	result, err := s.cloudinary.UploadFile(ctx, file, cloudinaryFilename)
	if err != nil {
		return nil, err
	}

	// 7. Resolve GPS provenance
	gpsSource := domain.GPSNone
	captureSource := domain.CaptureSource(req.CapturedVia)

	var lat, lng *float64
	if captureSource == domain.SourceCamera && req.Latitude != nil && req.Longitude != nil {
		// Camera capture — GPS from device
		lat = req.Latitude
		lng = req.Longitude
		gpsSource = domain.GPSDevice
	} else if req.GPSSource == string(domain.GPSManual) && req.Latitude != nil && req.Longitude != nil {
		// Manual override provided
		lat = req.Latitude
		lng = req.Longitude
		gpsSource = domain.GPSManual
	}
	// Gallery uploads: GPS stays nil, gpsSource stays "none"

	// 8. Parse captured_at (default to now)
	capturedAt := time.Now()
	if req.CapturedAt != "" {
		if t, err := time.Parse(time.RFC3339, req.CapturedAt); err == nil {
			capturedAt = t
		}
	}

	// 9. Persist media record
	media := &domain.Media{
		InspectionID: inspectionID,
		UploadedBy:   userID,
		CloudinaryID: result.PublicID,
		URL:          result.URL,
		Filename:     strings.TrimSuffix(cloudinaryFilename, ext),
		MimeType:     mimeType,
		SizeBytes:    fileHeader.Size,
		CapturedVia:  captureSource,
		Latitude:     lat,
		Longitude:    lng,
		GPSSource:    gpsSource,
		CapturedAt:   capturedAt,
	}

	if err := s.mediaRepo.Create(ctx, media); err != nil {
		// Rollback Cloudinary upload on DB failure
		_ = s.cloudinary.DeleteFile(ctx, result.PublicID)
		return nil, err
	}

	res := toMediaResponse(media)
	return &res, nil
}

// GetByInspection returns all media for an inspection.
func (s *MediaService) GetByInspection(ctx context.Context, inspectionID uuid.UUID) (*response.MediaListResponse, error) {
	mediaList, total, err := s.mediaRepo.FindByInspection(ctx, inspectionID)
	if err != nil {
		return nil, err
	}

	var items []response.MediaResponse
	for _, m := range mediaList {
		items = append(items, toMediaResponse(&m))
	}

	return &response.MediaListResponse{Media: items, Total: total}, nil
}

// Delete soft-deletes a media record and removes it from Cloudinary.
func (s *MediaService) Delete(ctx context.Context, id uuid.UUID) error {
	media, err := s.mediaRepo.FindByID(ctx, id)
	if err != nil {
		return err
	}

	// Remove from Cloudinary first
	_ = s.cloudinary.DeleteFile(ctx, media.CloudinaryID)

	return s.mediaRepo.SoftDelete(ctx, id)
}

// --- mapper ---

func toMediaResponse(m *domain.Media) response.MediaResponse {
	return response.MediaResponse{
		ID:           m.ID.String(),
		InspectionID: m.InspectionID.String(),
		UploadedBy:   m.UploadedBy.String(),
		URL:          m.URL,
		Filename:     m.Filename,
		MimeType:     m.MimeType,
		SizeBytes:    m.SizeBytes,
		CapturedVia:  string(m.CapturedVia),
		Latitude:     m.Latitude,
		Longitude:    m.Longitude,
		GPSSource:    string(m.GPSSource),
		CapturedAt:   m.CapturedAt,
		CreatedAt:    m.CreatedAt,
	}
}
