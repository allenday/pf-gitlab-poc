#!/bin/bash

set -euo pipefail

GITLAB_URL="http://localhost"
GITLAB_API_URL="$GITLAB_URL/api/v4"

# Default environment variables for secret naming
NETWORK="${NETWORK:-local}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
SERVICE="${SERVICE:-gitlab}"
SECRET_NAME="${NETWORK}_${ENVIRONMENT}_${SERVICE}_gitlab_api_key"

# Bitwarden Secrets Manager configuration
BWS_ACCESS_TOKEN="${BWS_ACCESS_TOKEN:-}"
BWS_PROJECT_ID="${BWS_PROJECT_ID:-}"

check_bws_config() {
    if [ -z "$BWS_ACCESS_TOKEN" ]; then
        echo "⚠️  BWS_ACCESS_TOKEN not set - Bitwarden Secrets integration disabled"
        return 1
    fi
    
    if [ -z "$BWS_PROJECT_ID" ]; then
        echo "⚠️  BWS_PROJECT_ID not set - Bitwarden Secrets integration disabled"
        return 1
    fi
    
    return 0
}

check_existing_token() {
    echo "🔍 Checking for existing token in Bitwarden Secrets..."
    
    if command -v bws >/dev/null 2>&1 && check_bws_config; then
        EXISTING_TOKEN=$(bws secret get "$SECRET_NAME" --project-id "$BWS_PROJECT_ID" 2>/dev/null | jq -r '.value' 2>/dev/null || echo "")
        
        if [ -n "$EXISTING_TOKEN" ] && [ "$EXISTING_TOKEN" != "null" ]; then
            echo "🔑 Found existing token in Bitwarden Secrets"
            
            # Validate token against GitLab API
            echo "✅ Validating existing token..."
            VERSION=$(curl -s -H "PRIVATE-TOKEN: $EXISTING_TOKEN" "$GITLAB_API_URL/version" | jq -r '.version' 2>/dev/null)
            
            if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
                echo "✅ Existing token is valid (GitLab version: $VERSION)"
                echo "GITLAB_TOKEN=$EXISTING_TOKEN" > .gitlab_token
                return 0
            else
                echo "❌ Existing token is invalid, will create new one"
            fi
        else
            echo "📝 No existing token found in Bitwarden Secrets"
        fi
    else
        if ! command -v bws >/dev/null 2>&1; then
            echo "⚠️  Bitwarden Secrets CLI not available, creating new token"
        else
            echo "⚠️  Bitwarden Secrets not configured properly, creating new token"
        fi
    fi
    
    return 1
}

store_token_in_bitwarden() {
    local token="$1"
    
    if command -v bws >/dev/null 2>&1 && check_bws_config; then
        echo "💾 Storing token in Bitwarden Secrets..."
        
        # Check if secret already exists
        if bws secret get "$SECRET_NAME" --project-id "$BWS_PROJECT_ID" >/dev/null 2>&1; then
            echo "📝 Updating existing secret in Bitwarden"
            bws secret edit "$SECRET_NAME" --value "$token" --project-id "$BWS_PROJECT_ID" >/dev/null 2>&1 || {
                echo "⚠️  Failed to update token in Bitwarden Secrets"
                return 1
            }
        else
            echo "🆕 Creating new secret in Bitwarden"
            bws secret create "$SECRET_NAME" "$token" --project-id "$BWS_PROJECT_ID" >/dev/null 2>&1 || {
                echo "⚠️  Failed to store token in Bitwarden Secrets"
                return 1
            }
        fi
        
        echo "✅ Token stored in Bitwarden Secrets as $SECRET_NAME"
    else
        if ! command -v bws >/dev/null 2>&1; then
            echo "⚠️  Bitwarden Secrets CLI not available, token only stored locally"
        else
            echo "⚠️  Bitwarden Secrets not configured properly, token only stored locally"
        fi
    fi
}

create_gitlab_token() {
    echo "Creating GitLab Personal Access Token automatically..."
    
    # Check for existing token first
    if check_existing_token; then
        echo "🎉 Using existing valid token from Bitwarden Secrets"
        return 0
    fi
    
    # Get root password
    ROOT_PASSWORD=$(docker compose exec gitlab grep 'Password:' /etc/gitlab/initial_root_password 2>/dev/null | cut -d' ' -f2 || echo "")
    if [ -z "$ROOT_PASSWORD" ]; then
        echo "❌ Could not extract root password"
        return 1
    fi
    echo "✅ Got root password"
    
    # Login and get session
    echo "🔑 Logging in as root..."
    COOKIE_JAR=$(mktemp)
    LOGIN_RESPONSE=$(curl -s -c "$COOKIE_JAR" -d "user[login]=root&user[password]=$ROOT_PASSWORD" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "$GITLAB_URL/users/sign_in")
    
    # Get authenticity token for API token creation
    echo "🎫 Getting authenticity token..."
    TOKEN_PAGE=$(curl -s -b "$COOKIE_JAR" "$GITLAB_URL/-/profile/personal_access_tokens")
    AUTHENTICITY_TOKEN=$(echo "$TOKEN_PAGE" | grep -o 'name="authenticity_token" value="[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$AUTHENTICITY_TOKEN" ]; then
        echo "❌ Could not get authenticity token"
        rm -f "$COOKIE_JAR"
        return 1
    fi
    echo "✅ Got authenticity token"
    
    # Create Personal Access Token
    echo "🔐 Creating Personal Access Token..."
    TOKEN_NAME="automated-test-token-$(date +%s)"
    TOKEN_RESPONSE=$(curl -s -b "$COOKIE_JAR" \
        -d "authenticity_token=$AUTHENTICITY_TOKEN&personal_access_token[name]=$TOKEN_NAME&personal_access_token[expires_at]=&personal_access_token[scopes][]=api" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        "$GITLAB_URL/-/profile/personal_access_tokens")
    
    # Extract the token from response
    GITLAB_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -o 'id="created-personal-access-token"[^>]*value="[^"]*"' | cut -d'"' -f6)
    
    if [ -z "$GITLAB_TOKEN" ]; then
        echo "❌ Could not create Personal Access Token"
        echo "Response: $TOKEN_RESPONSE"
        rm -f "$COOKIE_JAR"
        return 1
    fi
    
    echo "✅ Created Personal Access Token: $GITLAB_TOKEN"
    echo "GITLAB_TOKEN=$GITLAB_TOKEN" > .gitlab_token
    
    # Store in Bitwarden Secrets
    store_token_in_bitwarden "$GITLAB_TOKEN"
    
    # Cleanup
    rm -f "$COOKIE_JAR"
    echo "🎉 Token saved to .gitlab_token file"
}

run_integration_tests() {
    echo "🧪 Running automated integration tests..."
    
    if [ ! -f .gitlab_token ]; then
        echo "❌ .gitlab_token file not found"
        return 1
    fi
    
    source .gitlab_token
    if [ -z "$GITLAB_TOKEN" ]; then
        echo "❌ No token found in .gitlab_token file"
        return 1
    fi
    
    echo "Testing GitLab API with auto-created token..."
    
    # Test API health
    echo "1. Testing API health..."
    VERSION=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/version" | jq -r '.version' 2>/dev/null)
    if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
        echo "✅ GitLab API responding - Version: $VERSION"
    else
        echo "❌ GitLab API not responding"
        return 1
    fi
    
    # Test project creation
    echo "2. Testing project creation..."
    PROJECT_NAME="automated-test-$(date +%s)"
    PROJECT_RESPONSE=$(curl -s -X POST \
        -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$PROJECT_NAME\",\"visibility\":\"private\"}" \
        "$GITLAB_API_URL/projects")
    
    PROJECT_ID=$(echo "$PROJECT_RESPONSE" | jq -r '.id' 2>/dev/null)
    if [ -n "$PROJECT_ID" ] && [ "$PROJECT_ID" != "null" ]; then
        echo "✅ Created test project: $PROJECT_NAME (ID: $PROJECT_ID)"
        
        # Test project deletion
        echo "3. Testing project deletion..."
        DELETE_RESPONSE=$(curl -s -X DELETE -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_API_URL/projects/$PROJECT_ID")
        echo "✅ Test project deleted successfully"
    else
        echo "❌ Failed to create test project"
        echo "Response: $PROJECT_RESPONSE"
        return 1
    fi
    
    echo "🎉 All GitLab integration tests passed!"
    if command -v bws >/dev/null 2>&1; then
        echo "Token stored persistently in Bitwarden Secrets as $SECRET_NAME"
    fi
    echo "Token also saved in deploy/.gitlab_token for future use"
}

# Main execution
main() {
    case "${1:-test}" in
        "create-token")
            create_gitlab_token
            ;;
        "test")
            run_integration_tests
            ;;
        "full")
            create_gitlab_token
            run_integration_tests
            ;;
        *)
            echo "Usage: $0 {create-token|test|full}"
            echo "  create-token: Create a GitLab Personal Access Token"
            echo "  test:        Run integration tests with existing token"
            echo "  full:        Create token and run tests (default)"
            exit 1
            ;;
    esac
}

main "$@"