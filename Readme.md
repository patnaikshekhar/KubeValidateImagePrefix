# Image Prefix Dynamic Admission Controller Example 

This project is creates a validating webhook written in node which will check if the image prefex starts with a certain prefix. This can be used to validate if images are being pulled from only private / known registries

# Installation
To install this in your cluster run

```bash
./install.sh
```

# Tutorial
A common requirement that I've come across is to allow developers to only use known repositories when pulling images for their pods and not use random sources on docker hub. I thought it was a good opportunity to finally get my hands dirty with Dynamic Admission Control in kubernetes.

We'll first start by writing a simple node express app that listens on http port 443. We'll read self signed TLS certs from a path so that we can serve SSL traffic.

```bash
npm init -y
npm install express body-parser nodemon
```

We'll use the body-parser library to handle json requests which are sent by the kubernetes apiserver. We find all the containers in the request and find their corresponding images. For each of the images we then check if the images have the right prefix. If they don't then we return an error response.

```js
const express = require('express')
const bodyParser = require('body-parser')
const fs = require('fs')
const https = require('https')
const privateKey  = fs.readFileSync('./certs/tls.key')
const certificate = fs.readFileSync('./certs/tls.crt')

const app = express()
app.use(bodyParser.json())

app.post('/', (req, res) => {
    const request = req.body.request

    console.log('Got request', request)

    let response = {
        allowed: false
    }

    if ('object' in request) {
        console.log('Evaluating pod', request.object.metadata.name)
        if ('spec' in request.object) {
            if ('containers' in request.object.spec) {

                const images = request.object.spec.containers.map(cont => cont.image)
                const imagesWithoutPrefix =  images.filter(img => {
                    if (!img.startsWith(process.env.PREFIX)) {
                        return true
                    } else {
                        return false
                    }
                })

                console.log('Found the following images without prefix', imagesWithoutPrefix)
                if (imagesWithoutPrefix.length > 0) {
                    response = {
                        allowed: false,
                        status: {
                            status: 'Failure',
                            message: `The following containers have incorrect prefixes ${imagesWithoutPrefix.join(',')}`,
                            reason: `Only private images are allowed`,
                            code: 402
                        }
                    }
                } else {
                    response = {
                        allowed: true
                    }
                }
            }
        }
    }

    res.json({
        response
    })
})

const run = () => {
    const httpsServer = https.createServer({
        key: privateKey,
        cert: certificate
    }, app)
    httpsServer.listen(443)
    console.log('Server started')
}

run()
```

We then create a Dockerfile to be able to create an image for the app
```Dockerfile
FROM node
WORKDIR /app
EXPOSE 443

COPY . /app
RUN npm install

CMD ["npm", "start"]
```

The image is then built and pushed to the repository

```bash
docker build -t patnaikshekhar/validatingwebhookexample:v1alpha10 .
docker push patnaikshekhar/validatingwebhookexample:v1alpha9
```

We'll create a namespace in kubernetes to hold the pods and services for the webhook.

```bash
kubectl create ns development
```

We then need manifests to deploy the application to kubernetes. We'll start with the deployment manifest
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pod-validation
  namespace: development
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pod-validation
  template:
    metadata:
      labels:
        app: pod-validation
    spec:
      containers:
      - image: patnaikshekhar/validatingwebhookexample:v1alpha10
        name: main
        env:
        - name: PREFIX
          value: patnaikshekhar
        volumeMounts:
        - name: certs
          mountPath: /app/certs
      volumes:
      - name: certs
        secret:
          secretName: pod-validation-secret
```

In the deployment manifest we mount a secret containing the certs for TLS. The certs will be created via our install script.

We also need a manifest so that the pod can be exposed as a service so that the API Server can reach it

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pod-validation-service
  namespace: development
spec:
  type: ClusterIP
  selector:
    app: pod-validation
  ports:
  - protocol: TCP
    port: 443
```

The manifest creates a service of type cluster IP which points to the pod(s) created by the deployment.

Finally, we need an installation script that creates the certs, mounts it as a secret and then creates the manifest for the ValidatingWebhookConfiguration which needs the ca cert embedded in it.

```bash
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
```


License
----

MIT