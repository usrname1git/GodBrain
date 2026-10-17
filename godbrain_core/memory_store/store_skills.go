package memorystore

import (
	"context"
	"encoding/hex"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"golang.org/x/crypto/sha3"
)

var allowedSkillProfiles = map[string]struct{}{
	"local-edit-apply-v1": {},
	"galaxy-html-v1":      {},
	"frontend-spa-v1":     {},
	"frontend-nextjs-v1":  {},
	"desk-v1":             {},
}

var applyOnlySkillProfiles = map[string]struct{}{
	"local-edit-apply-v1": {},
}

var suiteRequiredSkillProfiles = map[string]struct{}{
	"galaxy-html-v1":     {},
	"frontend-spa-v1":    {},
	"frontend-nextjs-v1": {},
}

func latestSkillRunSort() bson.D {
	return bson.D{{Key: "created_at", Value: -1}, {Key: "_id", Value: -1}}
}

func normalizeSkillExtracted(skill SkillExtracted) SkillExtracted {
	skill.Name = strings.TrimSpace(skill.Name)
	skill.Content = strings.TrimSpace(skill.Content)
	skill.TaskKind = strings.ToLower(strings.Join(strings.Fields(skill.TaskKind), " "))
	skill.Framework = strings.ToLower(strings.TrimSpace(skill.Framework))
	skill.VerificationProfile = strings.TrimSpace(skill.VerificationProfile)
	if skill.VerificationProfile != "" {
		if _, ok := allowedSkillProfiles[skill.VerificationProfile]; !ok {
			skill.VerificationProfile = ""
		}
	}
	inputs := make([]string, 0, len(skill.RequiredInputs))
	for _, input := range skill.RequiredInputs {
		input = strings.TrimSpace(input)
		if input != "" {
			inputs = append(inputs, input)
		}
	}
	skill.RequiredInputs = inputs
	steps := make([]string, 0, len(skill.Procedure))
	for _, step := range skill.Procedure {
		step = strings.TrimSpace(step)
		if step != "" {
			steps = append(steps, step)
		}
	}
	skill.Procedure = steps
	return skill
}

func skillProcedureText(skill SkillExtracted) string {
	if skill.Content != "" {
		return skill.Content
	}
	return strings.Join(skill.Procedure, "\n")
}

func skillStableID(name, content string) string {
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte("skill\x00" + name + "\x00" + content))
	return hex.EncodeToString(hash.Sum(nil))
}

func validateSkillExtracted(skill SkillExtracted) error {
	if !safeExtractorIDPattern.MatchString(skill.Name) {
		return ErrInvalidSkillExtracted
	}
	content := skillProcedureText(skill)
	if content == "" || len(content) > 8192 {
		return ErrInvalidSkillExtracted
	}
	if len(skill.Procedure) > 32 {
		return ErrInvalidSkillExtracted
	}
	for _, step := range skill.Procedure {
		if len(step) > 512 {
			return ErrInvalidSkillExtracted
		}
	}
	if len(skill.RequiredInputs) > 16 {
		return ErrInvalidSkillExtracted
	}
	if skill.TaskKind != "" && (len(skill.TaskKind) > 64 || !safeExtractorIDPattern.MatchString(strings.ReplaceAll(skill.TaskKind, " ", "-"))) {
		return ErrInvalidSkillExtracted
	}
	if skill.Framework != "" && (len(skill.Framework) > 64 || !safeExtractorIDPattern.MatchString(skill.Framework)) {
		return ErrInvalidSkillExtracted
	}
	if skill.Confidence < 0 || skill.Confidence > 1 {
		return ErrInvalidSkillExtracted
	}
	return nil
}

func ValidateRecordSkillRun(request RecordSkillRunRequest) error {
	if request.Command != RecordSkillRunCommand {
		return ErrInvalidSkillRun
	}
	if !safeExtractorIDPattern.MatchString(request.SkillName) {
		return ErrInvalidSkillRun
	}
	if strings.TrimSpace(request.OriginNodeID) == "" || len(request.OriginNodeID) > 64 {
		return ErrInvalidSkillRun
	}
	if strings.TrimSpace(request.FixtureID) == "" || len(request.FixtureID) > 128 {
		return ErrInvalidSkillRun
	}
	if len(strings.TrimSpace(request.SuiteID)) > 128 {
		return ErrInvalidSkillRun
	}
	if len(strings.TrimSpace(request.VerificationVersion)) > 32 {
		return ErrInvalidSkillRun
	}
	if _, ok := allowedSkillProfiles[request.VerificationProfile]; !ok {
		return ErrInvalidSkillProfile
	}
	if request.Result != SkillRunPassed && request.Result != SkillRunFailed {
		return ErrInvalidSkillRun
	}
	if len(request.Checks) > 16 {
		return ErrInvalidSkillRun
	}
	for key, value := range request.Checks {
		if len(key) > 64 || len(value) > 64 {
			return ErrInvalidSkillRun
		}
	}
	if len(request.EnvironmentHash) > 128 || len(request.ArtifactHash) > 128 {
		return ErrInvalidSkillRun
	}
	if len(request.LogExcerpt) > 4096 {
		return ErrInvalidSkillRun
	}
	if len(strings.TrimSpace(request.Reasoning)) < MinJudgmentReason ||
		len(request.Reasoning) > MaxJudgmentReason {
		return ErrJudgmentReasoningRequired
	}
	return nil
}

func ValidatePromoteSkillRequest(request PromoteSkillRequest) error {
	if request.Command != PromoteSkillCommand {
		return ErrInvalidSkillRun
	}
	if !safeExtractorIDPattern.MatchString(request.Name) {
		return ErrInvalidSkillExtracted
	}
	if strings.TrimSpace(request.OriginNodeID) == "" {
		return ErrKnowledgeNodeNotFound
	}
	if strings.TrimSpace(request.OriginVersion) == "" || strings.TrimSpace(request.OriginHash) == "" {
		return ErrSkillOriginHashMismatch
	}
	if request.SchemaVersion == "" || len(request.SchemaVersion) > 64 {
		return ErrInvalidSkillExtracted
	}
	if len(strings.TrimSpace(request.Reasoning)) < MinJudgmentReason ||
		len(request.Reasoning) > MaxJudgmentReason {
		return ErrJudgmentReasoningRequired
	}
	if request.VerificationProfile != "" {
		if _, ok := allowedSkillProfiles[request.VerificationProfile]; !ok {
			return ErrInvalidSkillProfile
		}
	}
	return nil
}

func ValidateQuerySkillsRequest(request QuerySkillsRequest) error {
	if request.Command != QuerySkillsCommand {
		return ErrInvalidSkillRun
	}
	if len(request.Query) > 512 {
		return ErrInvalidSkillRun
	}
	return nil
}

func (s *Store) RecordSkillVerificationRun(ctx context.Context, request RecordSkillRunRequest) (*SkillVerificationRun, error) {
	if err := ValidateRecordSkillRun(request); err != nil {
		return nil, err
	}
	now := time.Now().UTC()
	run := SkillVerificationRun{
		RunID:               uuid.NewString(),
		SkillName:           request.SkillName,
		OriginNodeID:        strings.TrimSpace(request.OriginNodeID),
		FixtureID:           strings.TrimSpace(request.FixtureID),
		SuiteID:             strings.TrimSpace(request.SuiteID),
		VerificationProfile: request.VerificationProfile,
		VerificationVersion: strings.TrimSpace(request.VerificationVersion),
		EnvironmentHash:     strings.TrimSpace(request.EnvironmentHash),
		Result:              request.Result,
		Checks:              request.Checks,
		ArtifactHash:        strings.TrimSpace(request.ArtifactHash),
		LogExcerpt:          request.LogExcerpt,
		Reasoning:           strings.TrimSpace(request.Reasoning),
		CreatedAt:           now,
	}
	if _, err := s.db.Collection("skill_verification_runs").InsertOne(ctx, run); err != nil {
		return nil, err
	}
	return &run, nil
}

func (s *Store) requirePassingSkillRun(ctx context.Context, originNodeID, skillName string) (*SkillVerificationRun, error) {
	opts := options.FindOne().SetSort(latestSkillRunSort())
	var latest SkillVerificationRun
	err := s.db.Collection("skill_verification_runs").FindOne(ctx, bson.M{
		"origin_node_id": originNodeID,
		"skill_name":     skillName,
	}, opts).Decode(&latest)
	if err != nil {
		if errors.Is(err, mongo.ErrNoDocuments) {
			return nil, ErrSkillVerificationRequired
		}
		return nil, err
	}
	if latest.Result != SkillRunPassed {
		return nil, ErrSkillVerificationStale
	}
	if _, allowed := allowedSkillProfiles[latest.VerificationProfile]; !allowed || latest.RunID == "" {
		return nil, ErrSkillVerificationStale
	}
	if _, applyOnly := applyOnlySkillProfiles[latest.VerificationProfile]; applyOnly {
		return nil, ErrSkillApplyOnlyProfile
	}
	if _, needSuite := suiteRequiredSkillProfiles[latest.VerificationProfile]; needSuite {
		if err := s.requireDistinctPassingFixtures(
			ctx, originNodeID, skillName, latest.VerificationProfile, 2); err != nil {
			return nil, err
		}
	}
	return &latest, nil
}

func suiteRequiredProfile(profile string) bool {
	_, ok := suiteRequiredSkillProfiles[profile]
	return ok
}

func (s *Store) requireDistinctPassingFixtures(
	ctx context.Context,
	originNodeID, skillName, profile string,
	min int,
) error {
	opts := options.Find().SetSort(latestSkillRunSort()).SetLimit(50)
	cursor, err := s.db.Collection("skill_verification_runs").Find(ctx, bson.M{
		"origin_node_id":       originNodeID,
		"skill_name":           skillName,
		"verification_profile": profile,
	}, opts)
	if err != nil {
		return err
	}
	defer cursor.Close(ctx)
	var runs []SkillVerificationRun
	if err = cursor.All(ctx, &runs); err != nil {
		return err
	}
	if currentPassingFixtureCount(runs) < min {
		return ErrSkillSuiteRequired
	}
	return nil
}

// runs must be latest-first. Only the newest run per fixture counts.
func currentPassingFixtureCount(runs []SkillVerificationRun) int {
	seen := map[string]struct{}{}
	n := 0
	for _, run := range runs {
		id := strings.TrimSpace(run.FixtureID)
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		if run.Result == SkillRunPassed {
			n++
		}
	}
	return n
}

func (s *Store) QueryPromotedSkills(ctx context.Context, query string, limit int) ([]Skill, error) {
	if limit <= 0 {
		limit = 5
	}
	if limit > 25 {
		limit = 25
	}
	filter := bson.M{}
	query = strings.TrimSpace(query)
	if query != "" {
		terms := append(skillQueryTerms(query), query)
		clauses := make([]bson.M, 0, len(terms)*2)
		for _, term := range terms {
			for _, field := range []string{"name", "content"} {
				clauses = append(clauses, bson.M{field: bson.M{"$regex": regexpQuote(term), "$options": "i"}})
			}
		}
		filter = bson.M{"$or": clauses}
	}
	opts := options.Find().SetSort(bson.D{{Key: "created_at", Value: -1}, {Key: "name", Value: 1}}).SetLimit(100)
	cursor, err := s.db.Collection("skills").Find(ctx, filter, opts)
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	var skills []Skill
	if err = cursor.All(ctx, &skills); err != nil {
		return nil, err
	}
	sort.SliceStable(skills, func(i, j int) bool {
		return skillRelevance(query, skills[i].Name, skills[i].Content) > skillRelevance(query, skills[j].Name, skills[j].Content)
	})
	current := make([]Skill, 0, limit)
	for _, skill := range skills {
		if query != "" && skillRelevance(query, skill.Name, skill.Content) == 0 {
			continue
		}
		eligible, err := s.skillIsCurrent(ctx, skill)
		if err != nil {
			return nil, err
		}
		if eligible {
			current = append(current, skill)
		}
		if len(current) >= limit {
			break
		}
	}
	return current, nil
}

func asciiSkillLower(text string) string {
	bytes := []byte(text)
	for i, c := range bytes {
		if c >= 'A' && c <= 'Z' {
			bytes[i] = c + ('a' - 'A')
		}
	}
	return string(bytes)
}

func skillQueryTerms(query string) []string {
	const stops = "|a|an|and|are|can|could|for|from|help|how|in|is|it|of|on|please|the|this|to|using|what|with|"
	terms := make([]string, 0, 8)
	word := ""
	add := func() {
		if len(word) >= 2 && len(word) <= 64 && !strings.Contains(stops, "|"+word+"|") && len(terms) < 8 {
			found := false
			for _, prior := range terms {
				found = found || prior == word
			}
			if !found {
				terms = append(terms, word)
			}
		}
		word = ""
	}
	for _, c := range []byte(asciiSkillLower(query)) {
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c >= 128 {
			word += string([]byte{c})
		} else {
			add()
		}
	}
	add()
	return terms
}

func skillRelevance(query, name, content string) int {
	n, text, q := asciiSkillLower(name), asciiSkillLower(content), asciiSkillLower(query)
	score := 0
	if q != "" && strings.Contains(n, q) {
		score += 40
	}
	if q != "" && strings.Contains(text, q) {
		score += 8
	}
	for _, term := range skillQueryTerms(query) {
		if strings.Contains(n, term) {
			score += 10
		}
		if strings.Contains(text, term) {
			score += 2
		}
	}
	return score
}

func (s *Store) skillIsCurrent(ctx context.Context, skill Skill) (bool, error) {
	_, allowed := allowedSkillProfiles[skill.VerificationProfile]
	_, applyOnly := applyOnlySkillProfiles[skill.VerificationProfile]
	if skill.Name == "" || skill.Content == "" || len(skill.Content) > 8192 ||
		skill.OriginNodeID == "" || skill.OriginVersion == "" || skill.VerificationRunID == "" || !allowed || applyOnly {
		return false, nil
	}
	var node KnowledgeNode
	err := s.db.Collection("knowledge_nodes").FindOne(ctx, knowledgeNodeFilter(skill.OriginNodeID)).Decode(&node)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte(node.Content))
	if node.Status != "verified" || node.Sector == "personal" || node.Version != skill.OriginVersion ||
		node.Content != skill.Content || hex.EncodeToString(hash.Sum(nil)) != skill.OriginHash {
		return false, nil
	}
	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: bson.M{"node_id": node.ID}}},
		{{Key: "$lookup", Value: bson.M{"from": "ingestion_runs", "localField": "run_id", "foreignField": "run_id", "as": "run"}}},
		{{Key: "$match", Value: bson.M{"run.status": StatusCommitted}}},
		{{Key: "$limit", Value: 1}},
		{{Key: "$project", Value: bson.M{"_id": 1}}},
	}
	cursor, err := s.db.Collection("run_node_links").Aggregate(ctx, pipeline, options.Aggregate().SetMaxTime(time.Second))
	if err != nil {
		return false, err
	}
	defer cursor.Close(ctx)
	if !cursor.Next(ctx) {
		return false, cursor.Err()
	}
	latest, err := s.requirePassingSkillRun(ctx, skill.OriginNodeID, skill.Name)
	if err != nil {
		if errors.Is(err, ErrSkillVerificationRequired) || errors.Is(err, ErrSkillVerificationStale) ||
			errors.Is(err, ErrSkillApplyOnlyProfile) || errors.Is(err, ErrSkillSuiteRequired) {
			return false, nil
		}
		return false, err
	}
	return latest.VerificationProfile == skill.VerificationProfile, nil
}

func regexpQuote(value string) string {
	replacer := strings.NewReplacer(
		`\`, `\\`, `.`, `\.`, `+`, `\+`, `*`, `\*`, `?`, `\?`,
		`(`, `\(`, `)`, `\)`, `[`, `\[`, `]`, `\]`, `{`, `\{`,
		`}`, `\}`, `|`, `\|`, `^`, `\^`, `$`, `\$`,
	)
	return replacer.Replace(value)
}
