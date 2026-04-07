package client

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// InspectionData is a minimal struct for what report-service needs from inspection-service.
type InspectionData struct {
	ID             string              `json:"id"`
	ProjectName    string              `json:"project_name"`
	LocationName   string              `json:"location_name"`
	Date           time.Time           `json:"date"`
	InspectorName  string              `json:"inspector_name"`
	InspectorRole  string              `json:"inspector_role"`
	Status         string              `json:"status"`
	ChecklistItems []ChecklistItemData `json:"checklist_items"`
	AgreedActions  []ActionData        `json:"agreed_actions"`
	Comments       []CommentData       `json:"comments"`
}

type ChecklistItemData struct {
	Description string `json:"description"`
	Response    *bool  `json:"response"`
	Comment     string `json:"comment"`
}

type ActionData struct {
	Description string    `json:"description"`
	AssigneeID  string    `json:"assignee_id"`
	DueDate     time.Time `json:"due_date"`
	Status      string    `json:"status"`
	EvidenceURL string    `json:"evidence_url"`
}

type CommentData struct {
	ID        string    `json:"id"`
	AuthorID  string    `json:"author_id"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

// MediaData is fetched from media-service.
type MediaData struct {
	URL         string    `json:"url"`
	CapturedAt  time.Time `json:"captured_at"`
	CapturedVia string    `json:"captured_via"`
}

type InspectionClient struct {
	baseURL    string
	mediaURL   string
	httpClient *http.Client
}

func NewInspectionClient(inspectionServiceURL, mediaServiceURL string) *InspectionClient {
	return &InspectionClient{
		baseURL:    inspectionServiceURL,
		mediaURL:   mediaServiceURL,
		httpClient: &http.Client{Timeout: 15 * time.Second},
	}
}

func (c *InspectionClient) GetInspection(ctx context.Context, inspectionID, accessToken string) (*InspectionData, error) {
	url := fmt.Sprintf("%s/api/v1/inspections/%s", c.baseURL, inspectionID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("inspection fetch failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("inspection-service returned %d", resp.StatusCode)
	}

	var result struct {
		Data InspectionData `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return &result.Data, nil
}

func (c *InspectionClient) GetMedia(ctx context.Context, inspectionID, accessToken string) ([]MediaData, error) {
	url := fmt.Sprintf("%s/api/v1/media?inspection_id=%s", c.mediaURL, inspectionID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("media fetch failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("media-service returned %d", resp.StatusCode)
	}

	var result struct {
		Data struct {
			Media []MediaData `json:"media"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, err
	}
	return result.Data.Media, nil
}
