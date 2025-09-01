FROM public.ecr.aws/lambda/python:3.11

# Copy requirements and wheel file, then install dependencies
COPY requirements.txt awslabs_mcp_lambda_handler-0.1.8-py3-none-any.whl ${LAMBDA_TASK_ROOT}
RUN pip install --no-cache-dir -r requirements.txt

# Copy function code
COPY main.py ${LAMBDA_TASK_ROOT}

# Set the CMD to your handler
CMD ["main.lambda_handler"]
