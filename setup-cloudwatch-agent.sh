#!/bin/bash
# setup-cloudwatch-agent.sh — One-time setup: install and configure CloudWatch agent
# on the nightly benchmark instance to stream logs and system metrics to CloudWatch.
#
# Run once on the nightly instance:
#   bash ~/nightly-repo/setup-cloudwatch-agent.sh

set -euo pipefail

echo "Installing CloudWatch agent..."
sudo yum install -y amazon-cloudwatch-agent

echo "Writing CloudWatch agent config..."
sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << 'EOF'
{
  "metrics": {
    "namespace": "opensearch/nightly-instance",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system", "cpu_usage_iowait"],
        "metrics_collection_interval": 5,
        "totalcpu": true,
        "resources": ["*"]
      },
      "mem": {
        "measurement": ["mem_used_percent", "mem_available", "mem_total"],
        "metrics_collection_interval": 5
      },
      "disk": {
        "measurement": ["disk_used_percent", "disk_free", "disk_total"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      },
      "diskio": {
        "measurement": ["diskio_reads", "diskio_writes", "diskio_read_bytes", "diskio_write_bytes"],
        "metrics_collection_interval": 5,
        "resources": ["*"]
      },
      "net": {
        "measurement": ["net_bytes_sent", "net_bytes_recv", "net_packets_sent", "net_packets_recv"],
        "metrics_collection_interval": 5,
        "resources": ["*"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/home/ec2-user/nightly-adhoc.log",
            "log_group_name": "/opensearch/nightly/orchestrator",
            "log_stream_name": "{instance_id}-adhoc"
          },
          {
            "file_path": "/home/ec2-user/nightly-cron.log",
            "log_group_name": "/opensearch/nightly/orchestrator",
            "log_stream_name": "{instance_id}-cron"
          }
        ]
      }
    }
  }
}
EOF

echo "Starting CloudWatch agent..."
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

echo "CloudWatch agent started. Metrics and logs streaming to:"
echo "  Namespace: opensearch/nightly-instance"
echo "  Log group: /opensearch/nightly/orchestrator"
