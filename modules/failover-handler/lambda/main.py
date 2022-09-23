import boto3
import os
import logging
import json

from botocore.exceptions import ClientError


def get_active_tg_arn():
    return os.environ.get("ACTIVE_TG_ARN")


def get_passive_tg_arn():
    return os.environ.get("PASSIVE_TG_ARN")


def get_elb_arn():
    return os.environ.get("ELB_LISTENER_ARN")


client = boto3.client("elbv2")
logging.getLogger().setLevel(logging.INFO)


def handler(event, context):
    active_tg_arn = get_active_tg_arn()
    active_tg_health = get_tg_health(active_tg_arn)
    passive_tg_arn = get_passive_tg_arn()
    passive_tg_health = get_tg_health(passive_tg_arn)

    listener_arn = get_elb_arn()
    if active_tg_health != "healthy":
        logging.info(f"Active instance is not healthy (status={active_tg_health})")
        logging.info(f"Failing over to passive instance {passive_tg_arn}")
        success = set_elb_tg(listener_arn, passive_tg_arn)
        logging.info(f"Failed over to passive instance {passive_tg_arn}")

    return {"statusCode": 200}


def get_tg_health(arn) -> bool:

    try:
        response = client.describe_target_health(TargetGroupArn=arn)

        for item in response["TargetHealthDescriptions"]:
            health = item["TargetHealth"]["State"]
            return health

    except ClientError as e:
        logging.error(e)
        return False
    return True


def set_elb_tg(listener_arn, target_arn) -> bool:
    try:
        response = client.modify_listener(
            ListenerArn=listener_arn,
            DefaultActions=[
                {"Type": "forward", "TargetGroupArn": target_arn, "Order": 1}
            ],
        )
    except ClientError as e:
        logging.error(e)
        return False
    return True
