#/bin/bash

echo "Clean Up"
kubectl delete secret pod-validation-secret -n development
kubectl delete ValidatingWebhookConfiguration denypublicimages
kubectl delete -f k8s/deploy.yaml
rm -r certs

echo "Creating certs"
mkdir certs && cd certs
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -days 100000 -out ca.crt -subj "/CN=admission_ca"
cat >server.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = pod-validation-service
DNS.2 = pod-validation-service.development
DNS.3 = pod-validation-service.development.svc
EOF
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -out server.csr -subj "/CN=pod-validation-service.development.svc" -config server.conf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -days 100000 -extensions v3_req -extfile server.conf

echo "Creating Secret"
kubectl create secret tls pod-validation-secret --cert=tls.crt --key=tls.key -n development

cd ..

echo "Installing Webhook Pods"
kubectl apply -f k8s

echo "Creating Webhook"
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1beta1
kind: ValidatingWebhookConfiguration
metadata:
  name: denypublicimages
webhooks:
- name: denypublicimages.shekharpatnaik.com
  rules:
  - apiGroups:
    - ""
    apiVersions:
    - v1
    operations:
    - CREATE
    resources:
    - pods
  failurePolicy: Fail
  clientConfig:
    service:
      namespace: development
      name: pod-validation-service
    caBundle: $(cat ./certs/ca.crt | base64 | tr -d '\n')
EOF