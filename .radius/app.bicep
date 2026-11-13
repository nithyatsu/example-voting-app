extension radius

param environment string

@secure()
param postgresPassword string

@secure()
param registryPassword string

@secure()
param registryUsername string

var postgresDbUsername = 'myadmin'

resource exampleVotingApp 'Radius.Core/applications@2025-08-01-preview' = {
  name: 'example-voting-app'
  properties: {
    environment: environment
  }
}

resource postgresDb 'Radius.Data/postgreSqlDatabases@2025-08-01-preview' = {
  name: 'db'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    codeReference: 'result/server.js#L23'
    database: 'votes'
    password: postgresPassword
    size: 'S'
    tls: 'required'
    username: postgresDbUsername
  }
}

resource postgresSecret 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'postgres-client-credentials'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    codeReference: 'worker/Program.cs#L118'
    data: {
      password: {
        value: postgresPassword
      }
    }
  }
}

// Do not change this Secret's name value from 'radius-ghcr-registry-creds'.
// The containerImages recipe looks up registry credentials by that fixed name.
resource registryCreds 'Radius.Security/secrets@2025-08-01-preview' = {
  name: 'radius-ghcr-registry-creds'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    codeReference: '.radius/app.bicep'
    data: {
      password: {
        value: registryPassword
      }
      username: {
        value: registryUsername
      }
    }
  }
}

resource resultImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'result-image'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    build: {
      platforms: [
        'linux/amd64'
      ]
      source: 'git::https://github.com/nithyatsu/example-voting-app.git//result?ref=a73bd38f871a6d5ef0b9fc4e5db74e6fcbc472de'
    }
    codeReference: 'result/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource voteImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'vote-image'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    build: {
      platforms: [
        'linux/amd64'
      ]
      source: 'git::https://github.com/nithyatsu/example-voting-app.git//vote?ref=a73bd38f871a6d5ef0b9fc4e5db74e6fcbc472de'
    }
    codeReference: 'vote/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource workerImage 'Radius.Compute/containerImages@2025-08-01-preview' = {
  name: 'worker-image'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    build: {
      source: 'git::https://github.com/nithyatsu/example-voting-app.git//worker?ref=a73bd38f871a6d5ef0b9fc4e5db74e6fcbc472de'
    }
    codeReference: 'worker/Dockerfile'
  }
  dependsOn: [
    registryCreds
  ]
}

resource resultContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'result'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    codeReference: 'result/server.js#L89'
    containers: {
      result: {
        image: resultImage.properties.imageReference
        env: {
          PORT: {
            value: '80'
          }
          POSTGRES_DB: {
            value: postgresDb.properties.database
          }
          POSTGRES_HOST: {
            value: postgresDb.properties.host
          }
          POSTGRES_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: postgresSecret.name
                key: 'password'
              }
            }
          }
          POSTGRES_PORT: {
            value: '5432'
          }
          POSTGRES_SSLMODE: {
            value: 'require'
          }
          POSTGRES_USER: {
            value: postgresDbUsername
          }
        }
        ports: {
          web: {
            containerPort: 80
          }
        }
      }
    }
  }
}

resource voteContainer 'Radius.Compute/containers@2025-08-01-preview' = {
  name: 'vote'
  properties: {
    environment: environment
    application: exampleVotingApp.id
    codeReference: 'vote/app.py#L15'
    containers: {
      redis: {
        image: 'redis:7-alpine'
      }
      vote: {
        image: voteImage.properties.imageReference
        env: {
          REDIS_HOST: {
            value: 'localhost'
          }
          REDIS_PORT: {
            value: '6379'
          }
        }
        ports: {
          web: {
            containerPort: 80
          }
        }
      }
      worker: {
        image: workerImage.properties.imageReference
        env: {
          POSTGRES_DB: {
            value: postgresDb.properties.database
          }
          POSTGRES_HOST: {
            value: postgresDb.properties.host
          }
          POSTGRES_PASSWORD: {
            valueFrom: {
              secretKeyRef: {
                secretName: postgresSecret.name
                key: 'password'
              }
            }
          }
          POSTGRES_PORT: {
            value: '5432'
          }
          POSTGRES_SSLMODE: {
            value: 'Require'
          }
          POSTGRES_USER: {
            value: postgresDbUsername
          }
          REDIS_HOST: {
            value: 'localhost'
          }
          REDIS_PORT: {
            value: '6379'
          }
        }
      }
    }
  }
}
