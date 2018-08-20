#coding:GBK
import urllib2
import re
from bs4 import BeautifulSoup
from distutils.filelist import findall

wuliu_url = 'http://www.56885.net/zhuanxian/?18_191_0_0_0_0_0';

for yema in range(260):
    
    page = urllib2.urlopen(wuliu_url + '_' + str(yema) + '.html');
    #print (wuliu_url + '_' + str(yema) + '.html' );
    contents = page.read()
    soup = BeautifulSoup(contents,"html.parser")
    for tag in soup.find_all('li',class_='w370'):
        m_url = tag.find('a').get('href')
        print m_url
        
    
