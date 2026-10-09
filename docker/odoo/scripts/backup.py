"""pg_dump each database and upload it to MinIO/S3; prune old dumps."""

import datetime as dt
import os
import subprocess
import tempfile

import boto3

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ.get("MINIO_ENDPOINT") or None,
    aws_access_key_id=os.environ["MINIO_ACCESS_KEY"],
    aws_secret_access_key=os.environ["MINIO_SECRET_KEY"],
    region_name=os.environ.get("MINIO_REGION", "us-east-1"),
)
bucket = os.environ["BACKUP_BUCKET"]
retention = dt.timedelta(days=int(os.environ.get("BACKUP_RETENTION_DAYS", "14")))
stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

for db in filter(None, os.environ["BACKUP_DATABASES"].split(",")):
    with tempfile.NamedTemporaryFile(suffix=".dump") as dump:
        subprocess.run(["pg_dump", "-Fc", "-d", db, "-f", dump.name], check=True)
        key = f"postgres/{db}/{db}-{stamp}.dump"
        s3.upload_file(dump.name, bucket, key)
        print(f"Uploaded s3://{bucket}/{key}")

    cutoff = dt.datetime.now(dt.timezone.utc) - retention
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=f"postgres/{db}/")
    for page in pages:
        for obj in page.get("Contents", []):
            if obj["LastModified"] < cutoff:
                s3.delete_object(Bucket=bucket, Key=obj["Key"])
                print(f"Deleted old backup {obj['Key']}")
