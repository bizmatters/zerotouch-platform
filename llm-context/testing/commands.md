# Local/CI testing:
Kind cluster
    - in-cluster-test.sh
    - build-service.sh test
    - load-image-to-kind.sh 

# Env testing:
Kubernetes cluster
    - build-service.sh env
    - run-tests-in-env.sh dev



