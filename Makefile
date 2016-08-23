PACKAGE := github.com/znly/cloud-debug-go
NAME := gce_metadata_proxy

all:
	GOOS=linux go build -v -o cdbg/$(NAME)
