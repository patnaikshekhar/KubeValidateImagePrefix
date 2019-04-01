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