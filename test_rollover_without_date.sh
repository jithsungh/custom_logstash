#!/bin/bash

# ============================================================================
# Test Script: ILM Rollover Without Date
# ============================================================================
# This script validates that indices are created WITHOUT dates using ILM
# Expected: auto-nginx-000001, auto-nginx-000002, etc.
# NOT: auto-nginx-2025-11-18-000001
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ES_HOST="${ES_HOST:-localhost:9200}"
ES_USER="${ES_USER:-elastic}"
ES_PASS="${ES_PASS:-changeme}"
TEST_CONTAINER="testapp"
TEST_ALIAS="auto-${TEST_CONTAINER}"
EXPECTED_INDEX="${TEST_ALIAS}-000001"
POLICY_NAME="${TEST_ALIAS}-ilm-policy"
TEMPLATE_NAME="logstash-${TEST_ALIAS}"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}   ILM Rollover Without Date - Test Suite${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Helper functions
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}✗ $1 is not installed${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ $1 is available${NC}"
}

api_call() {
    local method=$1
    local path=$2
    local data=$3
    
    if [ -n "$data" ]; then
        curl -s -X "$method" \
            -u "${ES_USER}:${ES_PASS}" \
            -H "Content-Type: application/json" \
            "http://${ES_HOST}${path}" \
            -d "$data"
    else
        curl -s -X "$method" \
            -u "${ES_USER}:${ES_PASS}" \
            -H "Content-Type: application/json" \
            "http://${ES_HOST}${path}"
    fi
}

cleanup_test_resources() {
    echo -e "\n${YELLOW}Cleaning up test resources...${NC}"
    
    # Delete indices
    api_call DELETE "/${TEST_ALIAS}-*" > /dev/null 2>&1 || true
    
    # Delete template
    api_call DELETE "/_index_template/${TEMPLATE_NAME}" > /dev/null 2>&1 || true
    
    # Delete policy
    api_call DELETE "/_ilm/policy/${POLICY_NAME}" > /dev/null 2>&1 || true
    
    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

# Step 1: Check prerequisites
echo -e "\n${BLUE}[1] Checking prerequisites...${NC}"
check_command curl
check_command jq

# Step 2: Test Elasticsearch connection
echo -e "\n${BLUE}[2] Testing Elasticsearch connection...${NC}"
ES_VERSION=$(api_call GET "/" | jq -r '.version.number' 2>/dev/null)
if [ -z "$ES_VERSION" ] || [ "$ES_VERSION" == "null" ]; then
    echo -e "${RED}✗ Cannot connect to Elasticsearch at ${ES_HOST}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to Elasticsearch ${ES_VERSION}${NC}"

# Step 3: Cleanup existing test resources
cleanup_test_resources

# Step 4: Build and install the gem
echo -e "\n${BLUE}[3] Building the gem...${NC}"
cd /mnt/c/Users/jithsungh.v/logstash-output-elasticsearch
gem build logstash-output-elasticsearch.gemspec
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Gem built successfully${NC}"
    GEM_FILE=$(ls -t logstash-output-elasticsearch-*.gem | head -1)
    echo -e "${BLUE}   Gem file: ${GEM_FILE}${NC}"
else
    echo -e "${RED}✗ Gem build failed${NC}"
    exit 1
fi

# Step 5: Test with sample events
echo -e "\n${BLUE}[4] Testing with sample events...${NC}"
echo -e "${YELLOW}   Send test events through Logstash with the updated config${NC}"
echo -e "${YELLOW}   Then run the verification steps below${NC}"

# Step 6: Wait for user to send events
echo -e "\n${YELLOW}Press Enter after you've sent some test events through Logstash...${NC}"
read

# Step 7: Verify indices
echo -e "\n${BLUE}[5] Verifying indices...${NC}"
INDICES=$(api_call GET "/_cat/indices/${TEST_ALIAS}-*?h=index" 2>/dev/null)

if [ -z "$INDICES" ]; then
    echo -e "${RED}✗ No indices found for pattern ${TEST_ALIAS}-*${NC}"
    echo -e "${YELLOW}   Make sure you've sent events with container_name='${TEST_CONTAINER}'${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Found indices:${NC}"
echo "$INDICES" | while read index; do
    # Check if index name contains a date (YYYY-MM-DD or YYYY.MM.DD pattern)
    if echo "$index" | grep -qE '[0-9]{4}[-\.][0-9]{2}[-\.][0-9]{2}'; then
        echo -e "  ${RED}✗ ${index} (CONTAINS DATE - BAD!)${NC}"
        HAS_DATE_INDEX=1
    else
        echo -e "  ${GREEN}✓ ${index} (NO DATE - GOOD!)${NC}"
    fi
done

# Check specific expected index
if echo "$INDICES" | grep -q "^${EXPECTED_INDEX}$"; then
    echo -e "\n${GREEN}✓ Expected index ${EXPECTED_INDEX} exists${NC}"
else
    echo -e "\n${YELLOW}⚠ Expected index ${EXPECTED_INDEX} not found${NC}"
    echo -e "${YELLOW}   Found indices: ${INDICES}${NC}"
fi

# Step 8: Verify alias
echo -e "\n${BLUE}[6] Verifying write alias...${NC}"
ALIAS_INFO=$(api_call GET "/_cat/aliases/${TEST_ALIAS}?h=alias,index,is_write_index" 2>/dev/null)

if [ -z "$ALIAS_INFO" ]; then
    echo -e "${RED}✗ Alias ${TEST_ALIAS} not found${NC}"
else
    echo -e "${GREEN}✓ Alias ${TEST_ALIAS} exists${NC}"
    echo "$ALIAS_INFO" | while read line; do
        echo -e "  ${BLUE}${line}${NC}"
    done
    
    # Check for write index
    if echo "$ALIAS_INFO" | grep -q "true"; then
        echo -e "${GREEN}✓ Write alias is configured${NC}"
    else
        echo -e "${YELLOW}⚠ No write index found${NC}"
    fi
fi

# Step 9: Verify ILM policy
echo -e "\n${BLUE}[7] Verifying ILM policy...${NC}"
POLICY=$(api_call GET "/_ilm/policy/${POLICY_NAME}" 2>/dev/null)

if [ -z "$POLICY" ] || echo "$POLICY" | grep -q "\"error\""; then
    echo -e "${RED}✗ Policy ${POLICY_NAME} not found${NC}"
else
    echo -e "${GREEN}✓ Policy ${POLICY_NAME} exists${NC}"
    
    # Check for rollover action
    if echo "$POLICY" | jq -e '.*.policy.phases.hot.actions.rollover' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Rollover action configured${NC}"
        ROLLOVER_CONDITIONS=$(echo "$POLICY" | jq -r '.*.policy.phases.hot.actions.rollover')
        echo -e "${BLUE}   Rollover conditions:${NC}"
        echo "$ROLLOVER_CONDITIONS" | jq '.'
    else
        echo -e "${RED}✗ Rollover action not found in policy${NC}"
    fi
    
    # Check for delete phase
    if echo "$POLICY" | jq -e '.*.policy.phases.delete' > /dev/null 2>&1; then
        DELETE_MIN_AGE=$(echo "$POLICY" | jq -r '.*.policy.phases.delete.min_age')
        echo -e "${GREEN}✓ Delete phase configured (min_age: ${DELETE_MIN_AGE})${NC}"
    else
        echo -e "${YELLOW}⚠ Delete phase not configured${NC}"
    fi
fi

# Step 10: Verify template
echo -e "\n${BLUE}[8] Verifying index template...${NC}"
TEMPLATE=$(api_call GET "/_index_template/${TEMPLATE_NAME}" 2>/dev/null)

if [ -z "$TEMPLATE" ] || echo "$TEMPLATE" | grep -q "\"error\""; then
    echo -e "${RED}✗ Template ${TEMPLATE_NAME} not found${NC}"
else
    echo -e "${GREEN}✓ Template ${TEMPLATE_NAME} exists${NC}"
    
    # Check index patterns
    INDEX_PATTERNS=$(echo "$TEMPLATE" | jq -r '.index_templates[0].index_template.index_patterns[]' 2>/dev/null)
    echo -e "${BLUE}   Index patterns:${NC}"
    echo "$INDEX_PATTERNS" | while read pattern; do
        echo -e "     ${pattern}"
    done
    
    # Check ILM settings
    if echo "$TEMPLATE" | jq -e '.index_templates[0].index_template.template.settings.index.lifecycle.name' > /dev/null 2>&1; then
        ILM_POLICY=$(echo "$TEMPLATE" | jq -r '.index_templates[0].index_template.template.settings.index.lifecycle.name')
        echo -e "${GREEN}✓ ILM policy reference: ${ILM_POLICY}${NC}"
    fi
    
    if echo "$TEMPLATE" | jq -e '.index_templates[0].index_template.template.settings.index.lifecycle.rollover_alias' > /dev/null 2>&1; then
        ROLLOVER_ALIAS=$(echo "$TEMPLATE" | jq -r '.index_templates[0].index_template.template.settings.index.lifecycle.rollover_alias')
        echo -e "${GREEN}✓ Rollover alias: ${ROLLOVER_ALIAS}${NC}"
    else
        echo -e "${RED}✗ Rollover alias not configured in template${NC}"
    fi
fi

# Step 11: Verify index settings
echo -e "\n${BLUE}[9] Verifying index settings...${NC}"
if echo "$INDICES" | grep -q "^${EXPECTED_INDEX}$"; then
    INDEX_SETTINGS=$(api_call GET "/${EXPECTED_INDEX}/_settings" 2>/dev/null)
    
    if echo "$INDEX_SETTINGS" | jq -e ".\"${EXPECTED_INDEX}\".settings.index.lifecycle.name" > /dev/null 2>&1; then
        ILM_NAME=$(echo "$INDEX_SETTINGS" | jq -r ".\"${EXPECTED_INDEX}\".settings.index.lifecycle.name")
        echo -e "${GREEN}✓ ILM policy attached: ${ILM_NAME}${NC}"
    else
        echo -e "${RED}✗ No ILM policy attached to index${NC}"
    fi
    
    if echo "$INDEX_SETTINGS" | jq -e ".\"${EXPECTED_INDEX}\".settings.index.lifecycle.rollover_alias" > /dev/null 2>&1; then
        ROLLOVER_ALIAS=$(echo "$INDEX_SETTINGS" | jq -r ".\"${EXPECTED_INDEX}\".settings.index.lifecycle.rollover_alias")
        echo -e "${GREEN}✓ Rollover alias configured: ${ROLLOVER_ALIAS}${NC}"
    else
        echo -e "${RED}✗ Rollover alias not configured in index settings${NC}"
    fi
fi

# Step 12: Check ILM execution status
echo -e "\n${BLUE}[10] Checking ILM execution status...${NC}"
if echo "$INDICES" | grep -q "^${EXPECTED_INDEX}$"; then
    ILM_EXPLAIN=$(api_call GET "/${EXPECTED_INDEX}/_ilm/explain" 2>/dev/null)
    
    PHASE=$(echo "$ILM_EXPLAIN" | jq -r ".indices.\"${EXPECTED_INDEX}\".phase" 2>/dev/null)
    ACTION=$(echo "$ILM_EXPLAIN" | jq -r ".indices.\"${EXPECTED_INDEX}\".action" 2>/dev/null)
    STEP=$(echo "$ILM_EXPLAIN" | jq -r ".indices.\"${EXPECTED_INDEX}\".step" 2>/dev/null)
    
    echo -e "${BLUE}   Phase: ${PHASE}${NC}"
    echo -e "${BLUE}   Action: ${ACTION}${NC}"
    echo -e "${BLUE}   Step: ${STEP}${NC}"
    
    if [ "$PHASE" == "hot" ]; then
        echo -e "${GREEN}✓ Index is in hot phase (actively writing)${NC}"
    fi
fi

# Final summary
echo -e "\n${BLUE}================================================${NC}"
echo -e "${BLUE}                  SUMMARY${NC}"
echo -e "${BLUE}================================================${NC}"

# Count indices with and without dates
TOTAL_INDICES=$(echo "$INDICES" | wc -l)
INDICES_WITH_DATE=$(echo "$INDICES" | grep -cE '[0-9]{4}[-\.][0-9]{2}[-\.][0-9]{2}' || echo "0")
INDICES_WITHOUT_DATE=$((TOTAL_INDICES - INDICES_WITH_DATE))

echo -e "\n${BLUE}Indices:${NC}"
echo -e "  Total: ${TOTAL_INDICES}"
echo -e "  ${GREEN}Without date: ${INDICES_WITHOUT_DATE}${NC}"
echo -e "  ${RED}With date: ${INDICES_WITH_DATE}${NC}"

if [ "$INDICES_WITH_DATE" -eq 0 ]; then
    echo -e "\n${GREEN}✓✓✓ SUCCESS! All indices are created WITHOUT dates!${NC}"
    echo -e "${GREEN}    ILM rollover is working correctly!${NC}"
else
    echo -e "\n${RED}✗✗✗ FAILURE! Some indices still have dates!${NC}"
    echo -e "${YELLOW}    Make sure you're using the updated gem${NC}"
fi

echo -e "\n${BLUE}================================================${NC}"

# Offer to cleanup
echo -e "\n${YELLOW}Do you want to cleanup test resources? (y/n)${NC}"
read -r response
if [ "$response" == "y" ]; then
    cleanup_test_resources
    echo -e "${GREEN}✓ Test resources cleaned up${NC}"
fi

echo -e "\n${BLUE}Test complete!${NC}\n"
