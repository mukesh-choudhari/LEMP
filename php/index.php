<html>
<head><h1>Welcome to My LEMP Application</h1></head>
</body>
<?php

if(!isset($_SESSION['tempuser'])) // if the session not yet started
{
## Database connect starts here###

$localhost = '{MYSQL_HOST}';
$username = '{MYSQL_USER}';
$password = '{MYSQL_PASS}';

$con = mysqli_connect($localhost,$username,$password,'visitors') or exit('connection to db failed');
## Database connect ends here###

$sql="CREATE TABLE IF NOT EXISTS `visitor_details` (`serial` int(11) NOT NULL,`visitor_no` int(11) NOT NULL,PRIMARY KEY (`serial`))";
mysqli_query($con,$sql);

$fetch = mysqli_query($con,"select visitor_no from visitor_details WHERE serial=1");
$count = mysqli_num_rows($fetch);

if($count != 1 )
{
        $sql="INSERT INTO `visitor_details` (`serial`, `visitor_no`) VALUES ('1', '0')";
        mysqli_query($con,$sql);
}
$fetch = mysqli_query($con,"select visitor_no from visitor_details WHERE serial=1");
$row = mysqli_fetch_object($fetch);
$visitor_no = $row->visitor_no;
$visitor_no = $visitor_no + 1;
$_SESSION["tempuser"] = $visitor_no;

#$sql = "UPDATE visitor_details SET visitor_no=$visitor_no WHERE 'serial'=1;";
$sql = "UPDATE `visitor_details` SET `visitor_no`=$visitor_no WHERE 1";
mysqli_query($con,$sql);
mysqli_close($con);
}

if(isset($_SESSION['tempuser']))
{
echo "You are visitor no. ";
echo $_SESSION['tempuser'];
echo "<br><a href='clear.php'>clear session</a><br>";
echo "Clicking clear session will automatically create new session and thus update the visitor number !!";
echo "Refreshing the page will also increase visitor number !!";
}
?>

</body>
</html>
