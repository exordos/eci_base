# Exordos Core Base Image

This repository builds two base images for Exordos Core project. The images contain all necessary tools and libraries to be used in Exordos installations.

## Images

- **exordos-base** - Full-featured base image using Ubuntu 26 profile with 4.5GB disk size
- **exordos-base-minimal** - Minimal base image using Ubuntu 26 minimal profile with 3.8GB disk size

The key features are:

- [Universal Agent](https://github.com/infraguys/gcl_sdk/wiki/universal_agent) service.
- Exordos autoresize service. Grows partitions and filesystems (ext2/3/4 and xfs) up to the disk size, at every boot and, via a udev rule, when the hypervisor enlarges a disk of a running machine.
- Exordos bootstrap service. Runs the bootstrap scripts.

## 🛠️ Build

You need [DevTools](https://github.com/exordos/exordos) to build the image. Look at the [install](https://github.com/exordos/exordos/blob/master/README.md#install) section for details.

Run the build command:

```bash
exordos build -i ~/.ssh/key.pub -f .
```

Where `~/.ssh/key.pub` is your public key for the image.

This command builds both images: `exordos-base` and `exordos-base-minimal`.

### Environment Variables

You can customize the build using the following environment variables:

- `GEN_USER_PASSWD` - Set the default user password (default: "ubuntu")
- `GEN_SDK_VERSION` - Specify the SDK version to install (default: "3.0.5")
- `LOCAL_GENESIS_SDK_PATH` - Path to local SDK copy for development purposes

Examples:

```bash
# Set custom user password
export GEN_USER_PASSWD=secret
exordos build -i ~/.ssh/key.pub -f .

# Use specific SDK version
export GEN_SDK_VERSION=3.0.5
exordos build -i ~/.ssh/key.pub -f .

# Build with local copy of the SDK
export LOCAL_GENESIS_SDK_PATH=/path/to/gcl_sdk
exordos build -i ~/.ssh/key.pub -f .
```

## 🚀 Usage

Upload the image to your repository. Using API, CLI or web interface create a node with the image.

### Using exordos-base

```bash
curl --location 'http://10.20.0.2:11010/v1/nodes/' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer ****' \
--data '{

    "name": "vm",
    "project_id": "f1f14cf1-1639-40dc-b725-757506a202b4",
    "root_disk_size": 15,
    "cores": 1,
    "ram": 1024,
    "disk_spec": {
        "kind": "root_disk",
        "size": 15,
        "image": "http://10.20.0.1:8080/exordos-base/exordos-base.qcow2"
    }
}
```

### Using exordos-base-minimal

```bash
curl --location 'http://10.20.0.2:11010/v1/nodes/' \
--header 'Content-Type: application/json' \
--header 'Authorization: Bearer ****' \
--data '{

    "name": "vm",
    "project_id": "f1f14cf1-1639-40dc-b725-757506a202b4",
    "cores": 1,
    "ram": 1024,
    "disk_spec": {
        "kind": "root_disk",
        "size": 15,
        "image": "http://10.20.0.1:8080/exordos-base.qcow2"
    }
}
```

## 📃 Bootstrap scripts

For next images in hierarchy you can add scripts that are executed at the very first boot of the node. Actually it can be any executable file and not only bash scripts. Put your scripts in the `/var/lib/exordos/bootstrap/scripts` directory and they will be executed in the order of the files in the directory.
