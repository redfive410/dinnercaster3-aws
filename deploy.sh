#!/bin/bash

# AWS Lambda Docker Deployment Script
# Deploys a Python Lambda function using Docker to us-west-2

set -e  # Exit on any error

# Configuration
AWS_REGION="us-west-2"
FUNCTION_NAME="dinnercaster3-aws-docker"
ECR_REPO_NAME="dinnercaster3-aws-repo"
IMAGE_TAG="latest"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check if Docker is installed and running
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install it first."
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker daemon is not running. Please start Docker."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Please run 'aws configure'."
        exit 1
    fi
    
    print_success "Prerequisites check passed"
}

# Get AWS account ID
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        print_error "Failed to get AWS account ID"
        exit 1
    fi
    print_status "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Create ECR repository if it doesn't exist
create_ecr_repo() {
    print_status "Checking ECR repository..."
    
    if ! aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION &> /dev/null; then
        print_status "Creating ECR repository: $ECR_REPO_NAME"
        aws ecr create-repository \
            --repository-name $ECR_REPO_NAME \
            --region $AWS_REGION \
            --image-scanning-configuration scanOnPush=true
        print_success "ECR repository created"
    else
        print_status "ECR repository already exists"
    fi
}

# Login to ECR
ecr_login() {
    print_status "Logging in to ECR..."
    aws ecr get-login-password --region $AWS_REGION | \
        docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
    print_success "ECR login successful"
}

# Build Docker image
build_image() {
    print_status "Building Docker image..."
    
    IMAGE_URI="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:$IMAGE_TAG"
    
    # Clean up any existing images to avoid conflicts
    print_status "Cleaning up existing images..."
    docker rmi $ECR_REPO_NAME:$IMAGE_TAG 2>/dev/null || true
    docker rmi $IMAGE_URI 2>/dev/null || true
    
    # Ensure Docker buildx is available and create builder if needed
    print_status "Setting up Docker buildx..."
    if ! docker buildx ls | grep -q "lambda-builder"; then
        docker buildx create --name lambda-builder --driver docker-container --use
    else
        docker buildx use lambda-builder
    fi
    
    # Build with explicit platform targeting for Lambda compatibility using buildx
    print_status "Building for linux/amd64 platform..."
    docker buildx build \
        --platform linux/amd64 \
        --load \
        -t $ECR_REPO_NAME:$IMAGE_TAG \
        .
    
    # Tag for ECR
    docker tag $ECR_REPO_NAME:$IMAGE_TAG $IMAGE_URI
    
    # Verify the image architecture
    print_status "Verifying image architecture..."
    ARCH=$(docker inspect $ECR_REPO_NAME:$IMAGE_TAG --format='{{.Architecture}}')
    print_status "Built image architecture: $ARCH"
    
    if [ "$ARCH" != "amd64" ]; then
        print_error "Image was built for $ARCH instead of amd64. This may cause issues with Lambda."
        exit 1
    fi
    
    print_success "Docker image built successfully for $ARCH"
}

# Push image to ECR
push_image() {
    print_status "Pushing image to ECR..."
    
    docker push $IMAGE_URI
    
    print_success "Image pushed to ECR"
}

# Create IAM role for Lambda if it doesn't exist
create_lambda_role() {
    ROLE_NAME="lambda-execution-role"
    
    print_status "Checking Lambda execution role..."
    
    if ! aws iam get-role --role-name $ROLE_NAME &> /dev/null; then
        print_status "Creating Lambda execution role..."
        
        # Create trust policy
        cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
        
        aws iam create-role \
            --role-name $ROLE_NAME \
            --assume-role-policy-document file://trust-policy.json
        
        # Attach basic execution policy
        aws iam attach-role-policy \
            --role-name $ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        
        rm trust-policy.json
        
        print_success "Lambda execution role created"
        
        # Wait a bit for role to be available
        print_status "Waiting for role to be available..."
        sleep 10
    else
        print_status "Lambda execution role already exists"
    fi
    
    ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)
}

# Deploy Lambda function
deploy_lambda() {
    print_status "Deploying Lambda function..."
    
    if aws lambda get-function --function-name $FUNCTION_NAME --region $AWS_REGION &> /dev/null; then
        print_status "Updating existing Lambda function..."
        aws lambda update-function-code \
            --function-name $FUNCTION_NAME \
            --image-uri $IMAGE_URI \
            --region $AWS_REGION
        
        print_status "Updating function configuration..."
        aws lambda update-function-configuration \
            --function-name $FUNCTION_NAME \
            --timeout 30 \
            --memory-size 128 \
            --region $AWS_REGION
    else
        print_status "Creating new Lambda function..."
        aws lambda create-function \
            --function-name $FUNCTION_NAME \
            --package-type Image \
            --code ImageUri=$IMAGE_URI \
            --role $ROLE_ARN \
            --timeout 30 \
            --memory-size 128 \
            --region $AWS_REGION
    fi
    
    print_success "Lambda function deployed successfully"
}

# Add resource-based policy for Lambda function URL
add_function_url_policy() {
    print_status "Adding resource-based policy for function URL..."
    
    # Create the resource-based policy
    cat > function-url-policy.json << EOF
{
  "Version": "2012-10-17",
  "Id": "default",
  "Statement": [
    {
      "Sid": "FunctionURLAllowPublicAccess",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "lambda:InvokeFunctionUrl",
      "Resource": "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$FUNCTION_NAME",
      "Condition": {
        "StringEquals": {
          "lambda:FunctionUrlAuthType": "NONE"
        }
      }
    }
  ]
}
EOF
    
    # Apply the policy
    aws lambda add-permission \
        --function-name $FUNCTION_NAME \
        --statement-id FunctionURLAllowPublicAccess \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type NONE \
        --region $AWS_REGION 2>/dev/null || print_status "Policy may already exist"
    
    rm function-url-policy.json
    
    print_success "Function URL policy configured"
}

# Create Lambda function URL
create_function_url() {
    print_status "Creating Lambda function URL..."
    
    # Check if function URL already exists
    if aws lambda get-function-url-config --function-name $FUNCTION_NAME --region $AWS_REGION &> /dev/null; then
        print_status "Function URL already exists"
        FUNCTION_URL=$(aws lambda get-function-url-config --function-name $FUNCTION_NAME --region $AWS_REGION --query 'FunctionUrl' --output text)
    else
        print_status "Creating new function URL..."
        FUNCTION_URL=$(aws lambda create-function-url-config \
            --function-name $FUNCTION_NAME \
            --auth-type NONE \
            --cors MaxAge=86400,AllowMethods=GET,POST,PUT,DELETE,HEAD,AllowOrigins=*,AllowHeaders=content-type,x-amz-date,authorization,x-api-key,x-amz-security-token \
            --region $AWS_REGION \
            --query 'FunctionUrl' --output text)
        
        print_success "Function URL created"
    fi
    
    add_function_url_policy
    
    print_success "Function URL: $FUNCTION_URL"
}

# Main deployment function
main() {
    print_status "Starting AWS Lambda Docker deployment..."
    print_status "Function: $FUNCTION_NAME"
    print_status "Region: $AWS_REGION"
    print_status "ECR Repository: $ECR_REPO_NAME"
    echo ""
    
    check_prerequisites
    get_account_id
    create_ecr_repo
    ecr_login
    build_image
    push_image
    create_lambda_role
    deploy_lambda
    create_function_url
    
    print_success "Deployment completed successfully!"
    print_status "Function ARN: arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$FUNCTION_NAME"
    print_status "Function URL: $FUNCTION_URL"
    print_status "Image URI: $IMAGE_URI"
}

# Run main function
main
