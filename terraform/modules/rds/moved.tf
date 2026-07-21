moved {
  from = aws_db_instance.replica[0]
  to   = aws_db_instance.main[0]
}
