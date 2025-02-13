## NETWORKING
data "aws_vpc" "default" {
    id = "vpc-080aa58352099dcb7"
}

data "aws_subnet_ids" "private" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    tier = "private"
  }
}

## SECURITY GROUP

resource "aws_security_group" "sg" {
    name = "http"
    description = "Allow http and https traffict only"
    vpc_id = data.aws_vpc.default.id

    ingress {
        description = "TLS from VPC and the net"
        from_port   = 8000
        to_port     = 8000
        protocol    = "tcp"
        cidr_blocks = [data.aws_vpc.default.cidr_block, "0.0.0.0/0"]
    }
    
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "alb" {
    name = "${var.project_name}-sg-alb_http"
    description = "Allow http and https traffict only"
    vpc_id = data.aws_vpc.default.id

    ingress {
        description = "TLS from VPC and the net"
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = [data.aws_vpc.default.cidr_block, "0.0.0.0/0"]
    }
    
    
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

}


resource "aws_instance" "prod" {
    instance_type = "t2.micro"
    ami = "ami-0915bcb5fa77e4892"
    user_data = "${data.template_file.user_data.rendered}"
    security_groups = ["${aws_security_group.sg.name}"]
}


## AUTOSCALING GROUP

data "template_file" "user_data" {
template = "${file("./scripts/init.sh")}"
}

resource "aws_launch_configuration" "main" {
  name_prefix   = "${var.project_name}-lc-main"
  image_id      = "ami-04505e74c0741db8d"
  instance_type = "t2.micro"
  user_data = "${data.template_file.user_data.rendered}"
  iam_instance_profile = "ssm-role"
  security_groups = ["${aws_security_group.sg.id}"]


  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "backend" {
  name                 = "${var.project_name}-asg-main"
  launch_configuration = aws_launch_configuration.main.name
  min_size             = 1
  max_size             = 4
  vpc_zone_identifier = data.aws_subnet_ids.private.ids
  force_delete              = true
    target_group_arns = [aws_lb_target_group.main.arn] #  A list of aws_alb_target_group ARNs, for use with Application or Network Load Balancing.
  lifecycle {
    create_before_destroy = true
  }
  
  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]
  metrics_granularity = "1Minute"

 tag {
    key                 = "Name"
    value               = "backend"
    propagate_at_launch = true
  }

  depends_on = [aws_launch_configuration.main]
}

## LOAD BALANCER

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.alb.id}"]
  subnets            = data.aws_subnet_ids.private.ids

  enable_deletion_protection = false

  tags = {
    Environment = "production"
  }
}

resource "aws_lb_target_group" "main" {
  name        = "${var.project_name}-tg-main"
#   target_type = "instance"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_autoscaling_attachment" "asg_attachment_elb" {
  autoscaling_group_name = aws_autoscaling_group.backend.id
  alb_target_group_arn = aws_lb_target_group.main.arn
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}