#coding:GBK

import urllib2   
import re   
from bs4 import BeautifulSoup  
from distutils.filelist import findall  



page = urllib2.urlopen('http://www.56885.net/zhuanxian/?18_191_0_0_0_0_0.html')
page.encoding = 'utf-8'
contents = page.read()   
 
soup = BeautifulSoup(contents,"html.parser")#������ҳ
print("     ���� ")#��ӡ����


for tag in soup.find_all('li', class_='w370'):  #ѭ��ץȡ
    #m_name = tag.find('li', class_='w370')#.get_text()        
    #m_rating_score = float(tag.find('span',class_='rating_num').get_text())          
    m_people = tag.find_all('i') #Ѱ��P��ǩ
    #m_span = m_people.findAll('i') 
    #m_peoplecount = m_span[1].contents[0]  #ȡ��P
    m_url = tag.find('a').get('href')
    
    
    
    #print m_url.lstrip(".")
    print m_people
    #print m_span

