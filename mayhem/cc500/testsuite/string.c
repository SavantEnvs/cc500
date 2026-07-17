void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int main1();
int main() { return main1(); }
int main1()
{
  char *s;
  int j;
  s = "Hello";
  j = 0;
  while (s[j] != 0) {
    putchar(s[j]);
    j = j + 1;
  }
  putchar(10);
  return 0;
}
