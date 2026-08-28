package rag

import (
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode/utf8"
)

const DeskEvalVersion = "godbrain-desk-eval-v1"

type DeskEvalQuery struct {
	ID      string   `json:"id"`
	Query   string   `json:"query"`
	Needles []string `json:"needles"`
	Sector  string   `json:"sector,omitempty"`
}

type DeskEvalFile struct {
	Version string          `json:"version"`
	TopK    int             `json:"top_k"`
	Queries []DeskEvalQuery `json:"queries"`
}

type DeskEvalHit struct {
	ID      string   `json:"id"`
	Query   string   `json:"query"`
	Hit     bool     `json:"hit"`
	Count   int      `json:"count"`
	Needles []string `json:"matched_needles,omitempty"`
	Snippet string   `json:"snippet,omitempty"`
	Error   string   `json:"error,omitempty"`
}

type DeskEvalReport struct {
	Version    string        `json:"version"`
	Endpoint   string        `json:"endpoint"`
	Ready      bool          `json:"ready"`
	QueryCount int           `json:"query_count"`
	Hits       int           `json:"hits"`
	Misses     int           `json:"misses"`
	Empty      int           `json:"empty"`
	Queries    []DeskEvalHit `json:"queries"`
}

func DecodeDeskEvalFile(reader io.Reader) (DeskEvalFile, error) {
	var file DeskEvalFile
	decoder := json.NewDecoder(io.LimitReader(reader, 64*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&file); err != nil {
		return file, err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return file, errors.New("desk evaluation file must contain exactly one JSON document")
	}
	if file.Version != DeskEvalVersion {
		return file, errors.New("desk evaluation version is invalid")
	}
	if file.TopK < 1 || file.TopK > MaxTopK {
		return file, errors.New("desk evaluation top_k is invalid")
	}
	if len(file.Queries) == 0 || len(file.Queries) > 50 {
		return file, errors.New("desk evaluation query count is invalid")
	}
	seen := make(map[string]struct{}, len(file.Queries))
	for i, query := range file.Queries {
		query.ID = strings.TrimSpace(query.ID)
		query.Query = strings.TrimSpace(query.Query)
		query.Sector = strings.TrimSpace(query.Sector)
		if query.ID == "" || len(query.ID) > 64 {
			return file, errors.New("desk evaluation query id is invalid")
		}
		if _, dup := seen[query.ID]; dup {
			return file, errors.New("desk evaluation query id is duplicated")
		}
		seen[query.ID] = struct{}{}
		if query.Query == "" || utf8.RuneCountInString(query.Query) > MaxQueryRunes {
			return file, errors.New("desk evaluation query text is invalid")
		}
		if len(query.Needles) == 0 || len(query.Needles) > 8 {
			return file, errors.New("desk evaluation needles are invalid")
		}
		needles := make([]string, 0, len(query.Needles))
		for _, needle := range query.Needles {
			needle = strings.TrimSpace(needle)
			if needle == "" || utf8.RuneCountInString(needle) > 64 {
				return file, errors.New("desk evaluation needle is invalid")
			}
			needles = append(needles, needle)
		}
		query.Needles = needles
		file.Queries[i] = query
	}
	return file, nil
}

func MatchDeskNeedles(text string, needles []string) []string {
	lower := strings.ToLower(text)
	matched := make([]string, 0, len(needles))
	seen := make(map[string]struct{}, len(needles))
	for _, needle := range needles {
		key := strings.ToLower(needle)
		if _, dup := seen[key]; dup {
			continue
		}
		if strings.Contains(lower, key) {
			matched = append(matched, needle)
			seen[key] = struct{}{}
		}
	}
	return matched
}
