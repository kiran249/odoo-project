"""Create the MinIO bucket used for Odoo attachments if it does not exist."""

import os
import sys
import time

import boto3
from botocore.exceptions import ClientError, EndpointConnectionError

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["MINIO_ENDPOINT"],
    aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
    aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
    region_name=os.environ.get("MINIO_REGION", "us-east-1"),
)

for bucket in filter(None, os.environ.get("MINIO_BUCKETS", "").split(",")):
    bucket = bucket.strip()
    for attempt in range(30):
        try:
            s3.head_bucket(Bucket=bucket)
            print(f"Bucket '{bucket}' exists")
            break
        except ClientError as e:
            if e.response["Error"]["Code"] in ("404", "NoSuchBucket"):
                s3.create_bucket(Bucket=bucket)
                print(f"Bucket '{bucket}' created")
                break
            raise
        except EndpointConnectionError:
            print(f"MinIO not reachable yet (attempt {attempt + 1})")
            time.sleep(5)
    else:
        sys.exit(f"Could not reach MinIO at {os.environ['MINIO_ENDPOINT']}")
