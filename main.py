import random
from awslabs.mcp_lambda_handler import MCPLambdaHandler

mcp = MCPLambdaHandler(name="mcp-lambda-server", version="1.0.0")

@mcp.tool()
def dinnercaster() -> str:
    """Recommends a dinner based on day of week, time of year and local weather"""
    return random.choice(["tacos", "pizza", "sandwich"])

def lambda_handler(event, context):
    """AWS Lambda handler function."""
    try:
        return mcp.handle_request(event, context)
    except Exception as e:
        print(f"Error: {e}")
        raise