// Odoo 18 platform on EKS: Odoo + PostgreSQL + MinIO + Keycloak + Prometheus/Grafana
//
// Agent requirements: docker, aws CLI v2, kubectl, helm 3, jq, git.
// AWS access: the agent's IAM role, or a Jenkins "AWS Credentials" entry
// (CloudBees AWS Credentials plugin) whose ID is passed as AWS_CREDENTIALS_ID.
// That identity needs ECR push rights and access to the EKS cluster
// (an EKS access entry or aws-auth mapping with cluster-admin for this pipeline).

def withAws(Closure body) {
    if (params.AWS_CREDENTIALS_ID?.trim()) {
        withCredentials([[
            $class: 'AmazonWebServicesCredentialsBinding',
            credentialsId: params.AWS_CREDENTIALS_ID.trim(),
            accessKeyVariable: 'AWS_ACCESS_KEY_ID',
            secretKeyVariable: 'AWS_SECRET_ACCESS_KEY',
        ]]) { body() }
    } else {
        body()
    }
}

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 90, unit: 'MINUTES')
    }

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'prod'], description: 'Target environment (namespace odoo-<env>)')
        choice(name: 'ACTION', choices: ['deploy', 'destroy'], description: 'destroy removes the release but keeps the volumes')
        string(name: 'AWS_REGION', defaultValue: 'us-east-1', description: 'Region of the EKS cluster and ECR')
        string(name: 'EKS_CLUSTER_NAME', defaultValue: 'my-eks-cluster', description: 'Existing EKS cluster name')
        string(name: 'ECR_REPOSITORY', defaultValue: 'odoo-platform/odoo', description: 'ECR repository for the Odoo image (created if missing)')
        string(name: 'MINIO_ECR_REPOSITORY', defaultValue: 'odoo-platform/minio', description: 'ECR repository for the MinIO image built from source')
        string(name: 'AWS_CREDENTIALS_ID', defaultValue: '', description: 'Jenkins AWS credentials ID; empty = use the agent IAM role')
        booleanParam(name: 'BUILD_IMAGE', defaultValue: true, description: 'Build and push a new Odoo image')
        string(name: 'IMAGE_TAG', defaultValue: '', description: 'Image tag to deploy when BUILD_IMAGE is off (empty = computed from git)')
        booleanParam(name: 'DEPLOY_MONITORING', defaultValue: true, description: 'Install/upgrade kube-prometheus-stack + blackbox exporter')
        string(name: 'GRAFANA_SSO_ENV', defaultValue: 'prod', description: 'Environment whose Keycloak Grafana uses for login')
        string(name: 'ODOO_UPDATE_MODULES', defaultValue: '', description: 'Comma-separated Odoo modules to upgrade (-u) during this deploy, e.g. my_module or all')
    }

    environment {
        NAMESPACE = "odoo-${params.ENVIRONMENT}"
        MONITORING_NAMESPACE = 'monitoring'
        KUBECONFIG = "${WORKSPACE}/.kube/config"
        // Pin these once you have a known-good version: helm search repo prometheus-community
        // MinIO release built from source (docker/minio/Dockerfile); built once per release
        MINIO_RELEASE = 'RELEASE.2025-10-15T17-29-55Z'
        KPS_CHART_VERSION = ''
        BLACKBOX_CHART_VERSION = ''
    }

    stages {
        stage('Check tools') {
            steps {
                sh '''
                    set -e
                    for tool in docker aws kubectl helm jq git; do
                        command -v "$tool" >/dev/null || { echo "Missing tool on agent: $tool"; exit 1; }
                    done
                    helm version --short
                    kubectl version --client
                '''
            }
        }

        stage('Validate') {
            steps {
                sh '''
                    set -e
                    helm lint helm/odoo-platform -f environments/${ENVIRONMENT}/values.yaml
                    helm template odoo-platform helm/odoo-platform \
                        -n "$NAMESPACE" -f environments/${ENVIRONMENT}/values.yaml > /dev/null
                    for f in scripts/*.sh docker/odoo/scripts/init-db.sh; do bash -n "$f"; done
                '''
            }
        }

        stage('Resolve image') {
            steps {
                withAws {
                    script {
                        def account = sh(returnStdout: true, script: 'aws sts get-caller-identity --query Account --output text').trim()
                        env.REGISTRY = "${account}.dkr.ecr.${params.AWS_REGION}.amazonaws.com"
                        env.IMAGE_REPOSITORY = "${env.REGISTRY}/${params.ECR_REPOSITORY}"
                        env.MINIO_IMAGE = "${env.REGISTRY}/${params.MINIO_ECR_REPOSITORY}:${env.MINIO_RELEASE}"
                        def gitSha = sh(returnStdout: true, script: 'git rev-parse --short=8 HEAD').trim()
                        // Not named IMAGE_TAG: build parameters shadow env vars of the same name in sh steps
                        env.DEPLOY_TAG = params.IMAGE_TAG?.trim() ?: "${gitSha}-${env.BUILD_NUMBER}"
                        if (!params.BUILD_IMAGE && !params.IMAGE_TAG?.trim() && params.ACTION == 'deploy') {
                            error('BUILD_IMAGE is off: set IMAGE_TAG to an image that already exists in ECR')
                        }
                        echo "Image: ${env.IMAGE_REPOSITORY}:${env.DEPLOY_TAG}"
                    }
                }
            }
        }

        stage('Build & push images') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                withAws {
                    sh '''
                        set -e
                        ensure_repo() {
                            aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$1" >/dev/null 2>&1 \
                              || aws ecr create-repository --region "$AWS_REGION" --repository-name "$1" \
                                   --image-scanning-configuration scanOnPush=true >/dev/null
                        }
                        ensure_repo "$ECR_REPOSITORY"
                        ensure_repo "$MINIO_ECR_REPOSITORY"
                        aws ecr get-login-password --region "$AWS_REGION" \
                          | docker login --username AWS --password-stdin "$REGISTRY"

                        # MinIO: only built when this release is not in ECR yet
                        if aws ecr describe-images --region "$AWS_REGION" --repository-name "$MINIO_ECR_REPOSITORY" \
                             --image-ids imageTag="$MINIO_RELEASE" >/dev/null 2>&1; then
                            echo "MinIO image $MINIO_IMAGE already in ECR"
                        else
                            docker build --pull --build-arg MINIO_RELEASE="$MINIO_RELEASE" -t "$MINIO_IMAGE" docker/minio
                            docker push "$MINIO_IMAGE"
                        fi

                        if [ "$BUILD_IMAGE" = "true" ]; then
                            docker build --pull -f docker/odoo/Dockerfile -t "$IMAGE_REPOSITORY:$DEPLOY_TAG" .
                            docker push "$IMAGE_REPOSITORY:$DEPLOY_TAG"
                            docker rmi "$IMAGE_REPOSITORY:$DEPLOY_TAG" || true
                        fi
                    '''
                }
            }
        }

        stage('Connect to EKS') {
            steps {
                withAws {
                    sh '''
                        set -e
                        mkdir -p "$(dirname "$KUBECONFIG")"
                        aws eks update-kubeconfig --region "$AWS_REGION" --name "$EKS_CLUSTER_NAME" --kubeconfig "$KUBECONFIG"
                        kubectl get nodes -o wide
                    '''
                }
            }
        }

        stage('Approve production') {
            when { expression { params.ENVIRONMENT == 'prod' } }
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    input message: "${params.ACTION} ${env.DEPLOY_TAG} to PRODUCTION?", ok: 'Proceed'
                }
            }
        }

        stage('Cluster prerequisites') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                withAws {
                    sh '''
                        set -e
                        kubectl apply -f k8s/cluster/storageclass-gp3.yaml
                        kubectl get ingressclass alb >/dev/null 2>&1 \
                          || echo "WARNING: IngressClass 'alb' not found - install the AWS Load Balancer Controller"
                        kubectl get csidriver ebs.csi.aws.com >/dev/null 2>&1 \
                          || echo "WARNING: EBS CSI driver not found - volumes will stay Pending"
                    '''
                }
            }
        }

        stage('Secrets') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                withAws {
                    sh 'scripts/create-secrets.sh "$NAMESPACE"'
                }
            }
        }

        stage('Monitoring stack') {
            when { allOf { expression { params.ACTION == 'deploy' }; expression { params.DEPLOY_MONITORING } } }
            steps {
                withAws {
                    sh 'GRAFANA_SSO_NAMESPACE="odoo-${GRAFANA_SSO_ENV}" scripts/install-monitoring.sh'
                }
            }
        }

        stage('Deploy platform') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                withAws {
                    sh 'scripts/deploy-app.sh "$ENVIRONMENT" "$IMAGE_REPOSITORY" "$DEPLOY_TAG" "$ODOO_UPDATE_MODULES"'  // uses $MINIO_IMAGE
                }
            }
        }

        stage('Smoke test') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                withAws {
                    sh 'scripts/smoke-test.sh "$NAMESPACE"'
                }
            }
        }

        stage('Destroy') {
            when { expression { params.ACTION == 'destroy' } }
            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    input message: "Uninstall odoo-platform from ${env.NAMESPACE}? (PVCs and the secret are kept)", ok: 'Destroy'
                }
                withAws {
                    sh 'helm uninstall odoo-platform -n "$NAMESPACE" --wait || true'
                }
            }
        }
    }

    post {
        failure {
            script {
                if (fileExists(env.KUBECONFIG)) {
                    withAws {
                        sh '''
                            echo "---- Diagnostics for $NAMESPACE ----"
                            kubectl -n "$NAMESPACE" get pods,jobs,pvc,ingress -o wide || true
                            kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -40 || true
                            kubectl -n "$NAMESPACE" logs job/odoo-init --all-containers --tail=200 || true
                        '''
                    }
                }
            }
        }
        success {
            echo "Deployed ${env.IMAGE_REPOSITORY}:${env.DEPLOY_TAG} to ${env.NAMESPACE}"
        }
        always {
            sh 'rm -rf "$WORKSPACE/.kube"'
        }
    }
}
