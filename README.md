# Dev Container

## Run the container

```sh
docker run -d -e TERM=$TERM --name dev-container dev:1.1 tail -f /dev/null

docker exec -it dev-container fish
```
