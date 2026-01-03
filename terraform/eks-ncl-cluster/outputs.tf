output "cluster_name" {
  value = aws_eks_cluster.blue_green_deploymt.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.blue_green_deploymt.endpoint
}

output "node_group_name" {
  value = aws_eks_node_group.blue_green_deploymt_nodes.node_group_name
}
