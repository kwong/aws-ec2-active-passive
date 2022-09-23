resource "aws_lambda_function" "main" {
  function_name    = var.name
  description      = var.description
  filename         = var.artifact_file
  source_code_hash = var.artifact_file != null ? filebase64sha256(var.artifact_file) : null
  role             = aws_iam_role.lambda_role.arn
  handler          = var.handler
  runtime          = var.runtime
  memory_size      = var.memory_size
  timeout          = var.timeout

  environment {
    variables = var.environment
  }
}


# cloudwatch
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.cloudwatch_retention_days
  tags              = var.tags
}

# event bridge
resource "aws_cloudwatch_event_rule" "alb_check_trigger" {
  name                = "alb-failover-handler-event-rule"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "alb_check" {
  arn  = resource.aws_lambda_function.main.arn
  rule = aws_cloudwatch_event_rule.alb_check_trigger.name
}

resource "aws_lambda_permission" "alb_check" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = resource.aws_lambda_function.main.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alb_check_trigger.arn
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy.json
}

resource "aws_iam_role_policy" "lambda_cloudwatch_logs_policy" {
  name   = "${var.name}-lambda-cloudwatch-logs-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.lambda_policy.json
}

resource "aws_iam_role_policy" "lambda_alb_check_policy" {
  name   = "${var.name}-alb-check-policy"
  role   = aws_iam_role.lambda_role.id
  policy = data.aws_iam_policy_document.alb_check_policy.json
}


# ALB check policy
data "aws_iam_policy_document" "alb_check_policy" {
  statement {
    sid    = "ALBModify"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyListener",
    ]
    resources = [var.alb_listener_arn]
  }
  statement {
    sid    = "ALBCheck"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DescribeTargetHealth"
    ]
    resources = [
      "*"
    ]
  }
}


# Lambda Assume Role policy
data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    sid    = "LambdaExecRolePolicy"
    effect = "Allow"
    principals {
      identifiers = [
        "lambda.amazonaws.com",
      ]
      type = "Service"
    }
    actions = [
      "sts:AssumeRole",
    ]
  }
}

# Lambda CloudWatch Logs access
data "aws_iam_policy_document" "lambda_policy" {
  statement {
    sid    = "LambdaCreateCloudWatchLogGroup"
    effect = "Allow"
    actions = [
      "logs:PutLogEvents",
      "logs:CreateLogStream",
      "logs:CreateLogGroup"
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/lambda/*:*:*"
    ]
  }
}


data "archive_file" "lambdazip" {
  type        = "zip"
  output_path = "${path.module}/.uploads/failover_handler.zip"

  source_dir = "${path.module}/lambda/"
}
