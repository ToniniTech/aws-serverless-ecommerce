resource "aws_db_subnet_group" "payment" {
  name       = "${local.name_prefix}-payment"
  subnet_ids = aws_subnet.payment_private[*].id

  tags = {
    Name = "${local.name_prefix}-payment"
  }
}

resource "aws_db_instance" "payment" {
  identifier = "${local.name_prefix}-payment"

  engine         = "postgres"
  engine_version = "16"
  instance_class = var.payment_database_instance_class

  db_name                     = var.payment_database_name
  username                    = var.payment_database_username
  manage_master_user_password = true
  port                        = 5432

  allocated_storage = var.payment_database_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_subnet_group_name   = aws_db_subnet_group.payment.name
  vpc_security_group_ids = [aws_security_group.payment_database.id]
  publicly_accessible    = false
  multi_az               = var.payment_database_multi_az

  backup_retention_period    = var.payment_database_backup_retention_days
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection       = var.payment_database_deletion_protection
  skip_final_snapshot       = var.payment_database_skip_final_snapshot
  final_snapshot_identifier = var.payment_database_skip_final_snapshot ? null : "${local.name_prefix}-payment-final"

  performance_insights_enabled = var.payment_database_performance_insights
}
