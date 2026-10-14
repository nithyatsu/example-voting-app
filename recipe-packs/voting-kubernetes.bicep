extension radius

resource votingKubernetesRecipePack 'Radius.Core/recipePacks@2025-08-01-preview' = {
  name: 'voting-kubernetes'
  properties: {
    recipes: {
      'Radius.Compute/containers': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/containers:latest'
      }
      'Radius.Compute/persistentVolumes': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/persistentvolumes:latest'
      }
      'Radius.Security/secrets': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/secrets:latest'
      }
      'Radius.Data/postgreSqlDatabases': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/postgresqldatabases:latest'
      }
      'Radius.Data/redisCaches': {
        kind: 'bicep'
        source: 'ghcr.io/radius-project/kube-recipes/rediscaches:latest'
      }
    }
  }
}
