void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int main1();
int main() { return main1(); }
int main1()
{
  int c;
  c = '0';
  while (c <= '9') {
    putchar(c);
    c = c + 1;
  }
  putchar(10);
  return 0;
}
