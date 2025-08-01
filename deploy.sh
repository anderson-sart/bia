./build.sh
aws ecs update-service --cluster cluster-bia2 --service service-bia2  --force-new-deployment
