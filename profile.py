"""
Profile for a generic CloudLab cluster consisting of a specified number of nodes
and an NFS server. NFS server hosts users home directories as well as connected
CloudLab datasets. Each node has local storage mounted at /scratch. After the
cluster is instantiated you can check /var/tmp/startup-1.txt for log output from
the startup scripts.

Instructions:
Input parameters, instantiate, and wait for setup to complete before logging in
(otherwise setting up shared home directories on NFS might fail).
Bada-bing-bada-boom!
"""
import re

import geni.aggregate.cloudlab as cloudlab
import geni.portal as portal
import geni.rspec.pg as pg
import geni.urn as urn

# Portal context is where parameters and the rspec request is defined.
pc = portal.Context()

# The possible set of base disk-images that this cluster can be booted with.
# The second field of every tupule is what is displayed on the cloudlab
# dashboard.
images = [ ("UBUNTU14-64-STD", "Ubuntu 14.04"),
           ("UBUNTU16-64-STD", "Ubuntu 16.04") ]

# The possible set of node-types this cluster can be configured with. Currently 
# only m510 machines are supported.
hardware_types = [ ("m510", "m510 (CloudLab Utah, 8-Core Intel Xeon D-1548)"),
                   ("m400", "m400 (CloudLab Utah, 8-Core 64-bit ARMv8)"),
                   ("d430", "d430 (Emulab, 8-Core Intel Xeon E5-2630v3)") ]

pc.defineParameter("image", "Disk Image",
        portal.ParameterType.IMAGE, images[1], images,
        "Specify the base disk image that all the nodes of the cluster " +\
        "should be booted with.")

pc.defineParameter("hardware_type", "Hardware Type",
       portal.ParameterType.NODETYPE, hardware_types[0], hardware_types)

pc.defineParameter("username", "Username", 
        portal.ParameterType.STRING, "", None,
        "Username for which all user-specific software will be configured.")

# Number of nodes in the cluster besides the NFS server.
pc.defineParameter("num_nodes", "Nodes",
        portal.ParameterType.INTEGER, 1, [],
        "Specify the number of nodes. The total number of machines will be " +\
        "this plus the NFS servers.")        

# Size of partition to allocate for local disk storage.
pc.defineParameter("local_storage_size", "Size of Node Local Storage Partition",
        portal.ParameterType.STRING, "200GB", [],
        "Size of local disk partition to allocate for node-local storage.")

# Size of partition to allocate for NFS shared home directories.
pc.defineParameter("nfs_storage_size", "Size of NFS Shared Storage",
        portal.ParameterType.STRING, "200GB", [],
        "Size of disk partition to allocate on NFS server for hosting " +\
        "users' home directories.")

# Datasets to connect to the cluster (shared via NFS).
pc.defineParameter("dataset_urns", "datasets", 
        portal.ParameterType.STRING, "", None,
        "Space separated list of datasets to mount. All datasets are " +\
        "first mounted on the NFS server at /remote, and then mounted via " +\
        "NFS on all other nodes at /datasets/dataset-name")

params = pc.bindParameters()

# Create a Request object to start building the RSpec.
request = pc.makeRequestRSpec()

# Create a local area network for the cluster.
clan = request.LAN("clan")
clan.best_effort = True
clan.vlan_tagging = True
clan.link_multiplexing = True

# Create a special network for connecting datasets to the nfs server.
dslan = request.LAN("dslan")
dslan.best_effort = True
dslan.vlan_tagging = True
dslan.link_multiplexing = True

# Create array of the requested datasets
dataset_urns = []
if (params.dataset_urns != ""):
    dataset_urns = params.dataset_urns.split(" ")

nfs_datasets_export_dir = "/remote"

# Add datasets to the dataset-lan
for i in range(len(dataset_urns)):
    dataset_urn = dataset_urns[i]
    dataset_name = dataset_urn[dataset_urn.rfind("+") + 1:]
    rbs = request.RemoteBlockstore(
            "dataset%02d" % (i + 1), 
            nfs_datasets_export_dir + "/" + dataset_name, 
            "if1")
    rbs.dataset = dataset_urn
    dslan.addInterface(rbs.interface)

hostnames = ["nfs"]
for i in range(params.num_nodes):
    hostnames.append("n%d" % (i + 1))

nfs_shared_home_export_dir = "/local/nfs"
node_local_storage_dir = "/scratch"

# Setup the cluster one node at a time.
for host in hostnames:
    node = request.RawPC(host)
    node.hardware_type = params.hardware_type
    node.disk_image = urn.Image(cloudlab.Utah, "emulab-ops:%s" % params.image)

    # Install a private/public key on this node
    node.installRootKeys(True, True)

    node.addService(pg.Execute(shell="sh", 
        command="sudo /local/repository/system-setup.sh %s %s %s %s" % \
        (nfs_shared_home_export_dir, nfs_datasets_export_dir, 
        params.username, params.num_nodes)))

    # Add this node to the cluster LAN.
    clan.addInterface(node.addInterface("if1"))

    if host == "nfs":
        nfs_bs = node.Blockstore(host + "_nfs_bs", nfs_shared_home_export_dir)
        nfs_bs.size = params.nfs_storage_size
        # Add this node to the dataset blockstore LAN.
        if (len(dataset_urns) > 0):
            dslan.addInterface(node.addInterface("if2"))
    else:
        local_storage_bs = node.Blockstore(host + "_local_storage_bs", 
            node_local_storage_dir)
        local_storage_bs.size = params.local_storage_size

# Generate the RSpec
pc.printRequestRSpec(request)
