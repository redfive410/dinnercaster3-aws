from awslabs.mcp_lambda_handler import MCPLambdaHandler

mcp = MCPLambdaHandler(name="mcp-lambda-server", version="1.0.0")

@mcp.tool()
def dinnercaster() -> str:
    """Recommends a dinner based on day of week, time of year and local weather"""
    return "Tacos"

def lambda_handler(event, context):
    """AWS Lambda handler function."""
    import json
    
    try:
        # Handle different event types and validate JSON body if present
        body = event.get('body')
        
        if body is not None:
            # If body exists, ensure it's valid JSON
            if isinstance(body, str):
                # Check for control characters that cause JSON parsing issues
                if any(ord(c) < 32 and c not in '\t\n\r' for c in body):
                    return {
                        'statusCode': 400,
                        'body': json.dumps({
                            'error': 'Request body contains invalid control characters',
                            'details': f'Body length: {len(body)}, first 100 chars: {repr(body[:100])}'
                        })
                    }
                try:
                    json.loads(body)
                except json.JSONDecodeError as e:
                    return {
                        'statusCode': 400,
                        'body': json.dumps({
                            'error': 'Invalid JSON in request body',
                            'details': f'{str(e)}, body preview: {repr(body[:100])}'
                        })
                    }
            # If body is bytes, decode and validate
            elif isinstance(body, bytes):
                try:
                    body_str = body.decode('utf-8')
                    # Check for control characters in decoded string
                    if any(ord(c) < 32 and c not in '\t\n\r' for c in body_str):
                        return {
                            'statusCode': 400,
                            'body': json.dumps({
                                'error': 'Decoded request body contains invalid control characters',
                                'details': f'Body length: {len(body_str)}, first 100 chars: {repr(body_str[:100])}'
                            })
                        }
                    json.loads(body_str)
                    # Update event with decoded body
                    event['body'] = body_str
                except (UnicodeDecodeError, json.JSONDecodeError) as e:
                    return {
                        'statusCode': 400,
                        'body': json.dumps({
                            'error': 'Invalid request body format',
                            'details': f'{str(e)}, raw body preview: {repr(body[:100])}'
                        })
                    }
        
        return mcp.handle_request(event, context)
    except Exception as e:
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': 'Internal server error',
                'details': str(e)
            })
        }