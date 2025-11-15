Run container with host user:

```sh
docker run -it --rm \
    -e USER_ID=$(id -u) \
    -e GROUP_ID=$(id -g) \
    -e USERNAME=$(whoami) \
    -v ./src:/app \
    main-dev-container:light-0.1.1 \
    /bin/bash
```
