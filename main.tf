provider "aws" {
  region = "us-east-1"
}

resource "aws_sqs_queue" "queue" {
  name = "queue"
  delay_seconds = 0
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount = 3
  })

  tags = {
    Team = var.team
    Project = var.project
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "dlq" {
  name = "queue-dlq"
  delay_seconds = 0

  tags = {
    Team = var.team
    Project = var.project
    Environment = var.environment
  }
}

resource "aws_iam_role" "role" {
  name = "send_message_to_queue"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    Team = var.team
    Project = var.project
    Environment = var.environment
  }
}

data "aws_iam_policy" "logs_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_iam_role_policy_attachment" "logs_policy_attachment" {
  role = aws_iam_role.role.name
  policy_arn = data.aws_iam_policy.logs_policy.arn
}

resource "aws_iam_role_policy" "send_message_policy" {
  name = "allow_send_message_to_queue"
  role = aws_iam_role.role.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:SendMessage"
      ],
      "Resource": "${aws_sqs_queue.queue.arn}"
    }
  ]
}
EOF
}

resource "aws_api_gateway_rest_api" "api" {
  name = "api"

  tags = {
    Team = var.team
    Project = var.project
    Environment = var.environment
  }
}

resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id = aws_api_gateway_rest_api.api.root_resource_id
  path_part = "v1"
}

resource "aws_api_gateway_resource" "enqueue" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id = aws_api_gateway_resource.v1.id
  path_part = "enqueue"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.enqueue.id
  http_method = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.enqueue.id
  http_method = aws_api_gateway_method.post.http_method
  type = "AWS"
  integration_http_method = "POST"
  uri = "arn:aws:apigateway:us-east-1:sqs:path/${replace(replace(aws_sqs_queue.queue.arn, "arn:aws:sqs:us-east-1:", ""), ":", "/")}"
  credentials = aws_iam_role.role.arn
  passthrough_behavior = "NEVER"
  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }
  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)"
  }
}

resource "aws_api_gateway_method_response" "response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.enqueue.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.enqueue.id
  http_method = aws_api_gateway_method.post.http_method
  status_code = aws_api_gateway_method_response.response.status_code
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on = [aws_api_gateway_integration.integration]

  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name = "production"

  lifecycle {
    create_before_destroy = true
  }
}
